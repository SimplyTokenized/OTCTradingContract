// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEligibilityRegistry} from "./compliance/IEligibilityRegistry.sol";

/**
 * @title OTCTrading (v2)
 * @notice One trading contract per tenant, one OFFERING per tradable instrument.
 *
 * @dev v1 was a venue for a single token: `baseToken` was contract-wide, so a tenant listing a
 * second instrument had to deploy, govern, monitor and upgrade a second contract — and a third, and
 * a fortieth. v2 moves every property that was really a property of the instrument into an
 * {Offering}: its base token, its fee schedule and fee recipient, its order-size band, its default
 * expiry, its allowed counterparty tokens, and its compliance gate. One deployment now runs many
 * books, each configured and paused on its own.
 *
 * BREAKING: there is no upgrade path from 1.x. Storage layout and most of the external API changed;
 * v2 is deployed fresh and 1.x instances keep serving their own order books until they are drained.
 *
 * CUSTODY — orders are backed by an ALLOWANCE, not a deposit. Makers keep their funds in their own
 * wallet and both legs settle atomically at fill time via `transferFrom`. There is one exception: a
 * BUY order priced in native ETH must ESCROW `counterpartyAmount + makerFee` at creation, because an
 * allowance can pull ERC-20 at a later fill but nothing can pull native ETH from a maker who is not
 * present in the taker's transaction. Escrow is tracked per order in {ethEscrowed} and the unfilled
 * remainder is credited back to the maker on cancel/cleanup.
 *
 * ETH PAYOUTS USE PULL PAYMENTS. Amounts owed to a resting party (a maker's ETH proceeds or escrow
 * refund, and a fee recipient's fees) are booked into {pendingWithdrawals} and claimed later via
 * {withdraw}; they are never pushed. A maker or fee recipient that cannot receive ETH therefore can
 * never block settlement, a cancel, or a compliance force-cancel — they just accrue a claimable
 * balance. Only the active caller (the taker) is paid inline.
 *
 * ONE OFFERING CAN NEVER SPEND ANOTHER'S MONEY. This is the property that makes a tenant-wide
 * contract safe to operate, and it is enforced two ways rather than trusted:
 *   - ETH is reserved. Every wei held here is either escrow for a specific order ({ethEscrowed},
 *     summed in {totalEthEscrowed}) or a booked withdrawal ({pendingWithdrawals}, summed in
 *     {totalPendingWithdrawals}). {approveRescueAssets} can only ever touch the difference between
 *     the balance and those two sums, so the emergency path cannot reach a user's money.
 *     Invariant: `address(this).balance >= totalEthEscrowed + totalPendingWithdrawals`.
 *   - ERC-20 never enters. Both legs move maker-to-taker directly, so an ERC-20 balance here is
 *     always stray — never another offering's float.
 *
 * COMPLIANCE — one pluggable gate per offering, fixed for its life, three postures:
 *   1. address(0)                — ungated; anyone may trade the offering.
 *   2. WhitelistRegistry         — an operator-kept on-chain list (companion contract).
 *   3. ERC3643EligibilityAdapter — the security token's own identity registry decides: an
 *      INDEPENDENT compliance layer, which is what a regulated issuer's counsel actually requires.
 * The gate is checked when an order is CREATED and again, for BOTH sides, when it is FILLED — so a
 * maker whose verification lapses while their order rests stops trading without anyone sweeping the
 * book. It fails CLOSED: a registry that reverts blocks the trade rather than waving it through.
 * Exiting is never gated — {cancelOrder}, {batchCancelOrders} and {withdraw} stay open to a
 * de-listed address, because a compliance gate must stop new trading, not confiscate.
 *
 * GOVERNANCE — enforced in code, not left to key policy:
 *   - Duties are split. OPERATOR runs the venue day-to-day (open offerings, list counterparty
 *     tokens, set size bands, pause an offering, force-cancel a sanctioned maker's orders). ADMIN
 *     guards the contract (global pause, fee schedules, and proposing the riskiest changes).
 *     APPROVER is the second pair of eyes. UPGRADER authorizes implementation upgrades.
 *   - The irreversible or value-directing actions take FOUR EYES: changing where an offering's fees
 *     go, closing an offering for good, changing the trusted forwarder, and rescuing stray assets
 *     each require a proposal by the owning role and an approval by an APPROVER **who is not the
 *     proposer**. A proposal binds its exact parameters and lapses after {PROPOSAL_TTL}.
 *   - Role grants are DELAYED by {ROLE_GRANT_DELAY} and revocations are not, so the role-admin root
 *     cannot arm a second approver and self-approve in one transaction, while a compromised key
 *     stays removable this second.
 *   - Governance is never relayed: every role check, proposal and approval reads `msg.sender`, so
 *     a trusted forwarder can act as a trader but never as a key that runs the venue.
 *   - {DEFAULT_ADMIN_ROLE} and {UPGRADER_ROLE} still control the role graph and the code; both
 *     belong on a multisig behind a timelock. Users hold standing allowances here, so an upgrade
 *     must be publicly visible long enough for them to revoke and exit before it lands.
 *
 * @notice Fee-on-transfer tokens are NOT supported, as a base token or as a counterparty token:
 * settlement moves an exact amount between two parties and a transfer fee would silently short one
 * of them. Rebasing tokens are equally unsuitable as a base token.
 */
contract OTCTrading is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Errors ============
    //
    // Custom errors rather than revert strings: four bytes at the revert site instead of a stored
    // literal, which is what keeps a contract this size inside the 24KB limit with room for an
    // audit to add to it. The names carry the meaning the strings did.

    /// @dev invalid admin
    error InvalidAdmin();
    /// @dev invalid approver
    error InvalidApprover();
    /// @dev approver must not be admin
    error ApproverMustNotBeAdmin();
    /// @dev invalid base token
    error InvalidBaseToken();
    /// @dev invalid fee recipient
    error InvalidFeeRecipient();
    /// @dev counterparty token is the offering's base token
    error CounterpartyIsBaseToken();
    /// @dev fee above MAX_FEE_BPS
    error FeeTooHigh();
    /// @dev order-size band is empty or inverted
    error InvalidOrderSizeBounds();
    /// @dev the named eligibility registry cannot answer
    error RegistryNotAnswering();
    /// @dev offering not found
    error OfferingNotFound();
    /// @dev offering is not accepting trades
    error OfferingNotActive();
    /// @dev offering is closed for good
    error OfferingIsClosed();
    /// @dev offering is already in that state
    error OfferingStateUnchanged();
    /// @dev offering still has live orders
    error OfferingHasOpenOrders();
    /// @dev counterparty token already allowed on this offering
    error TokenAlreadyAllowed();
    /// @dev counterparty token not allowed on this offering
    error TokenNotAllowed();
    /// @dev address is not eligible to trade this offering
    error NotEligible();
    /// @dev the gate reverted, so eligibility is unknown — which is never "may trade"
    error EligibilityCheckUnavailable();
    /// @dev order not active
    error OrderNotActive();
    /// @dev order expired
    error OrderExpired();
    /// @dev caller is not the order's maker
    error NotOrderMaker();
    /// @dev a maker cannot fill their own order
    error CannotFillOwnOrder();
    /// @dev invalid fill amount
    error InvalidFillAmount();
    /// @dev fill exceeds the order's remaining size
    error ExceedsOrderSize();
    /// @dev the fill settles to zero counterparty tokens
    error FillRoundsToZero();
    /// @dev order size below the offering's minimum
    error OrderSizeBelowMinimum();
    /// @dev order size above the offering's maximum
    error OrderSizeAboveMaximum();
    /// @dev invalid counterparty amount
    error InvalidCounterpartyAmount();
    /// @dev price too low
    error PriceTooLow();
    /// @dev a partial fill below the offering's minimum that is not the order's remainder
    error FillBelowMinimum();
    /// @dev counterparty token is not a contract
    error InvalidCounterpartyToken();
    /// @dev the offering must be paused first
    error OfferingNotPaused();
    /// @dev incorrect ETH amount escrowed
    error IncorrectEthAmount();
    /// @dev this call does not take ETH
    error EthNotAccepted();
    /// @dev insufficient ETH sent
    error InsufficientEthSent();
    /// @dev the maker has not approved enough of their side
    error InsufficientAllowance();
    /// @dev the maker does not hold enough of their side
    error InsufficientBalance();
    /// @dev nothing to withdraw
    error NothingToWithdraw();
    /// @dev native transfer failed
    error EthTransferFailed();
    /// @dev invalid batch size
    error InvalidBatchSize();
    /// @dev invalid page size
    error InvalidPageSize();
    /// @dev no such proposal
    error NoSuchProposal();
    /// @dev proposal expired
    error ProposalExpired();
    /// @dev approver must not be proposer
    error ApproverMustNotBeProposer();
    /// @dev not allowed to cancel
    error NotAllowedToCancel();
    /// @dev invalid account
    error InvalidAccount();
    /// @dev already has role
    error AlreadyHasRole();
    /// @dev no pending grant
    error NoPendingGrant();
    /// @dev grant not scheduled
    error GrantNotScheduled();
    /// @dev grant still waiting
    error GrantStillWaiting();
    /// @dev grant expired
    error GrantExpired();
    /// @dev invalid recipient
    error InvalidRecipient();
    /// @dev the amount asked for is reserved for users
    error AmountIsReserved();
    /// @dev reserve accounting broken
    error ReserveAccountingBroken();
    /// @dev a relayed call must not carry value
    error RelayedCallCannotCarryValue();

    // ============ Roles ============

    /// @notice Guards the contract: global pause, fee schedules, and proposing the riskiest changes.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Runs the venue day-to-day: offerings, listings, size bands, compliance cancels.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice The second pair of eyes: approves what someone else proposed.
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    /// @notice Authorizes implementation upgrades. MUST be a timelock + multisig.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Constants ============

    /// @dev Ceiling for every array-taking function, to stay inside a block's gas.
    uint256 public constant MAX_BATCH_SIZE = 200;
    /// @dev Ceiling for a single page of a paginated view.
    uint256 public constant MAX_PAGE_SIZE = 200;
    /// @notice Highest fee an offering may charge either side: 10%.
    uint256 public constant MAX_FEE_BPS = 1000;
    /// @dev Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @notice How long a proposal stays approvable before it lapses.
    uint256 public constant PROPOSAL_TTL = 7 days;

    /**
     * @notice How long a role grant must wait between being scheduled and taking effect.
     *
     * @dev This is what stops four-eyes being defeated in a single transaction. Without it, whoever
     * holds a role's admin could grant {APPROVER_ROLE} to a second address they control and then
     * approve their own proposal in the very next call — two signatures, one person, four eyes in
     * name only.
     *
     * The delay is deliberately one-directional: **granting waits, revoking does not.** A
     * compromised key must be removable this second, while an added one is the thing that needs
     * daylight.
     */
    uint256 public constant ROLE_GRANT_DELAY = 2 days;

    /// @dev Lowest price an order may carry, as counterparty-per-base scaled by 1e18. There is
    /// deliberately no UPPER band: a 0-decimal share priced at a thousand ETH is an ordinary
    /// tokenized asset, and any ceiling that would catch a fat-fingered price would also catch it.
    /// Overflow is not the ceiling's job either — settlement uses a 512-bit mulDiv.
    uint256 private constant _MIN_PRICE = 1;

    /// @dev Length of the ERC-2771 calldata suffix carrying the original sender.
    uint256 private constant _CONTEXT_SUFFIX_LENGTH = 20;

    // ============ Types ============

    /// @notice Which side of the base token the MAKER is on.
    enum OrderType {
        BUY, // 0 - the maker buys base tokens, paying counterparty tokens
        SELL // 1 - the maker sells base tokens for counterparty tokens
    }

    /// @notice Where an offering is in its life.
    enum OfferingState {
        Active, // 0 - open for new orders and fills
        Paused, // 1 - no new orders and no fills; cancelling and withdrawing still work
        Closed // 2 - finished for good; irreversible
    }

    /// @notice The four actions that require four eyes.
    enum ActionKind {
        SetOfferingFeeRecipient, // redirect an offering's fees
        CloseOffering, // end an offering for good
        SetTrustedForwarder, // change who may relay calls
        RescueAssets // recover stray assets
    }

    /**
     * @notice One tradable instrument: its token, its economics, its rules.
     * @dev Everything here was contract-wide in v1. `baseToken` and `eligibilityRegistry` are fixed
     * for the offering's life — an order resting on the book must not have the asset it settles in,
     * or the gate it was admitted under, changed underneath it.
     */
    struct Offering {
        uint256 offeringId;
        address baseToken; // the ERC-20 traded in this offering
        address feeRecipient; // where this offering's fees go; four-eyes to change
        address eligibilityRegistry; // compliance gate, fixed for life; address(0) means ungated
        OfferingState state;
        uint16 makerFeeBps; // current schedule; each order snapshots it at creation
        uint16 takerFeeBps;
        uint48 defaultOrderExpiration; // seconds added at creation; 0 means orders never expire
        uint256 minOrderSize;
        uint256 maxOrderSize; // 0 means no limit
        uint256 openOrderCount; // live orders; must reach 0 before the offering can close
        bytes32 offeringRef; // the off-chain offering this book belongs to; the join key for evidence
        bool initialized;
    }

    /// @dev Creation parameters for {createOffering}, as a struct so the signature stays readable.
    struct OfferingConfig {
        address baseToken;
        address feeRecipient;
        address eligibilityRegistry;
        uint16 makerFeeBps;
        uint16 takerFeeBps;
        uint48 defaultOrderExpiration;
        uint256 minOrderSize;
        uint256 maxOrderSize;
        bytes32 offeringRef;
        address[] counterpartyTokens;
    }

    /**
     * @notice One resting order on one offering's book.
     * @dev Fee rates are snapshotted at creation so a later schedule change cannot be applied
     * retroactively to orders already on the book. Fields are packed: the maker slot carries the
     * flags, the fees and the expiry; the counterparty-token slot carries the creation stamp.
     */
    struct Order {
        uint256 id;
        uint256 offeringId;
        address maker;
        OrderType orderType;
        bool isActive;
        uint16 makerFeeBps;
        uint16 takerFeeBps;
        uint48 expiresAt; // 0 means it never expires
        address counterpartyToken; // address(0) means the chain's native asset
        uint48 createdAt;
        uint256 baseTokenAmount;
        uint256 counterpartyTokenAmount;
        uint256 filledAmount; // in base-token units
    }

    /// @dev Everything one fill settles, gathered once so {fillOrder} can check, write and transfer
    /// in three readable steps instead of carrying a dozen locals through all three.
    struct Fill {
        uint256 orderId;
        address maker;
        address taker;
        address baseToken;
        address counterpartyToken;
        address feeRecipient;
        uint256 baseTokenAmount;
        uint256 counterpartyTokenAmount;
        uint256 makerFee;
        uint256 takerFee;
        bool isSell;
        bool isEth;
    }

    /// @notice A pending four-eyes action, waiting for an approver who is not its proposer.
    struct Proposal {
        address proposer;
        uint64 proposedAt;
    }

    // ============ Storage ============

    /// @dev Counter for offering ids; starts at 1 so 0 always means "none".
    uint256 public nextOfferingId;
    /// @dev Counter for order ids; starts at 1 so 0 always means "none".
    uint256 public nextOrderId;

    /// @dev ERC-2771 forwarder, in storage rather than immutable so a tenant can turn relaying on
    /// or off without a new implementation.
    address private _trustedForwarder;

    /// @notice Sum of {ethEscrowed} across every live order. Reserved: never rescuable.
    uint256 public totalEthEscrowed;
    /// @notice Sum of {pendingWithdrawals} across every account. Reserved: never rescuable.
    uint256 public totalPendingWithdrawals;

    mapping(uint256 => Offering) private _offerings;
    mapping(uint256 => Order) private _orders;

    /// @notice offeringId => token => may an order on this offering settle in it.
    /// address(0) means the chain's native asset, which an offering must opt into like any other.
    mapping(uint256 => mapping(address => bool)) public offeringCounterpartyTokens;

    /// @notice Native ETH escrowed for a BUY+ETH order; zero for every other order kind. There is
    /// no `receive`/`fallback`, so a plain transfer to this contract reverts: the only ETH ever held
    /// backs either live escrow or an unclaimed withdrawal.
    mapping(uint256 => uint256) public ethEscrowed;

    /// @notice Claimable ETH booked for a party (maker proceeds and refunds, fee-recipient fees).
    /// Pull-payment: the owner calls {withdraw}.
    mapping(address => uint256) public pendingWithdrawals;

    /// @dev Order ids per offering and per maker, in creation order. Paginated views read these
    /// instead of scanning every id ever issued, which in a tenant-wide contract would mean walking
    /// other offerings' books to answer a question about one.
    mapping(uint256 => uint256[]) private _offeringOrderIds;
    mapping(address => uint256[]) private _makerOrderIds;

    /// @notice proposal id => the pending proposal. Ids bind kind and parameters, so an approval can
    /// only ever execute exactly what was proposed.
    mapping(bytes32 => Proposal) public proposals;

    /// @notice keccak256(role, account) => when the grant was scheduled. 0 means no pending grant.
    mapping(bytes32 => uint64) public roleGrantScheduledAt;

    // ============ Events ============

    event OfferingCreated(
        uint256 indexed offeringId,
        address indexed baseToken,
        bytes32 indexed offeringRef,
        address feeRecipient,
        address eligibilityRegistry
    );
    event OfferingStateChanged(uint256 indexed offeringId, OfferingState state);
    event OfferingFeesUpdated(uint256 indexed offeringId, uint16 makerFeeBps, uint16 takerFeeBps);
    event OfferingLimitsUpdated(
        uint256 indexed offeringId, uint256 minOrderSize, uint256 maxOrderSize, uint48 defaultOrderExpiration
    );
    event OfferingFeeRecipientUpdated(uint256 indexed offeringId, address indexed feeRecipient);
    event CounterpartyTokenAllowed(uint256 indexed offeringId, address indexed token);
    event CounterpartyTokenDisallowed(uint256 indexed offeringId, address indexed token);

    event OrderCreated(
        uint256 indexed orderId,
        uint256 indexed offeringId,
        address indexed maker,
        OrderType orderType,
        address counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount,
        uint48 expiresAt
    );
    event OrderFilled(
        uint256 indexed orderId,
        uint256 indexed offeringId,
        address indexed taker,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount,
        uint256 makerFee,
        uint256 takerFee
    );
    event OrderCancelled(uint256 indexed orderId, uint256 indexed offeringId, address indexed maker);
    event OrderAdminCancelled(uint256 indexed orderId, address indexed maker, address indexed by);
    event OrderCleanedUp(uint256 indexed orderId, uint256 indexed offeringId, address indexed maker);
    event OrdersCleanedUp(uint256 cleanedCount);
    event EthEscrowRefunded(uint256 indexed orderId, address indexed maker, uint256 amount);
    event EthCredited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    event TrustedForwarderUpdated(address indexed forwarder);
    event AssetsRescued(address indexed token, address indexed to, uint256 amount);
    event ActionProposed(bytes32 indexed proposalId, ActionKind indexed kind, address indexed proposer);
    event ActionApproved(bytes32 indexed proposalId, ActionKind indexed kind, address indexed approver);
    event ActionCancelled(bytes32 indexed proposalId, address indexed by);
    event RoleGrantScheduled(bytes32 indexed role, address indexed account, uint256 effectiveFrom, address indexed by);
    event RoleGrantCancelled(bytes32 indexed role, address indexed account, address indexed by);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract for one tenant. Offerings are opened afterwards, one call each —
     * which is the whole point of v2: the contract knows nothing about any instrument until an
     * operator lists one.
     * @param _admin Guards the contract, runs the venue, administers roles.
     * @param _approver The second pair of eyes. MUST differ from `_admin` — four-eyes is structural
     *        here, not a policy hope, so the split exists from the first block.
     * @param _upgrader Authorizes UUPS upgrades. Should be a timelock + multisig; users hold
     *        standing allowances here and need a public window to exit before new code lands.
     * @param forwarder_ ERC-2771 forwarder, or address(0) for "callers pay their own gas".
     */
    function initialize(address _admin, address _approver, address _upgrader, address forwarder_) public initializer {
        __AccessControl_init();
        __Pausable_init();

        if (_admin == address(0)) revert InvalidAdmin();
        if (_approver == address(0)) revert InvalidApprover();
        if (_approver == _admin) revert ApproverMustNotBeAdmin();
        if (_upgrader == address(0)) revert InvalidAccount();

        nextOfferingId = 1;
        nextOrderId = 1;
        // address(0) is a valid value here: it means "no relaying".
        // slither-disable-next-line missing-zero-check
        _trustedForwarder = forwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(APPROVER_ROLE, _approver);
        _grantRole(UPGRADER_ROLE, _upgrader);

        if (forwarder_ != address(0)) {
            emit TrustedForwarderUpdated(forwarder_);
        }
    }

    /**
     * @dev Authorize a UUPS implementation upgrade. Restricted to {UPGRADER_ROLE}, which MUST be a
     * timelock + multisig so upgrades are time-delayed and publicly visible: users hold standing
     * allowances (and BUY+ETH makers hold escrow) here and need a window to exit before a new
     * implementation takes effect. Storage is append-only across upgrades, enforced by the
     * OpenZeppelin upgrades validator.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Offerings ============

    /**
     * @dev Open a new offering: one tradable instrument with its own token, economics and rules.
     * @param cfg The offering's configuration. `baseToken` and `eligibilityRegistry` are fixed for
     *        its life; everything else can be tuned later by the role that owns it.
     * @return offeringId The id of the offering, which every order on it carries.
     *
     * @notice An offering starts {OfferingState.Active}. It is inert until someone trades it, which
     * is why opening one is an operator action rather than a four-eyes one — while CLOSING one, and
     * redirecting its fees, are not.
     */
    function createOffering(OfferingConfig calldata cfg)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        returns (uint256 offeringId)
    {
        if (cfg.baseToken.code.length == 0) revert InvalidBaseToken();
        // The venue must not pay itself: ETH fees would land in a withdrawal slot nothing can
        // claim, and ERC-20 fees would sit here looking like a stray transfer.
        if (cfg.feeRecipient == address(0) || cfg.feeRecipient == address(this)) revert InvalidFeeRecipient();
        if (cfg.makerFeeBps > MAX_FEE_BPS || cfg.takerFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (cfg.minOrderSize == 0) revert InvalidOrderSizeBounds();
        if (cfg.maxOrderSize != 0 && cfg.maxOrderSize < cfg.minOrderSize) revert InvalidOrderSizeBounds();
        if (cfg.counterpartyTokens.length > MAX_BATCH_SIZE) revert InvalidBatchSize();
        if (cfg.eligibilityRegistry != address(0)) {
            // Fail at listing, not at the first order, if the gate cannot answer.
            (bool answered,) = _queryEligibility(cfg.eligibilityRegistry, address(this));
            if (!answered) revert RegistryNotAnswering();
        }

        offeringId = nextOfferingId;
        nextOfferingId++;

        Offering storage offering = _offerings[offeringId];
        offering.offeringId = offeringId;
        offering.baseToken = cfg.baseToken;
        offering.feeRecipient = cfg.feeRecipient;
        offering.eligibilityRegistry = cfg.eligibilityRegistry;
        offering.state = OfferingState.Active;
        offering.makerFeeBps = cfg.makerFeeBps;
        offering.takerFeeBps = cfg.takerFeeBps;
        offering.defaultOrderExpiration = cfg.defaultOrderExpiration;
        offering.minOrderSize = cfg.minOrderSize;
        offering.maxOrderSize = cfg.maxOrderSize;
        offering.offeringRef = cfg.offeringRef;
        offering.initialized = true;

        emit OfferingCreated(offeringId, cfg.baseToken, cfg.offeringRef, cfg.feeRecipient, cfg.eligibilityRegistry);
        emit OfferingFeesUpdated(offeringId, cfg.makerFeeBps, cfg.takerFeeBps);
        emit OfferingLimitsUpdated(offeringId, cfg.minOrderSize, cfg.maxOrderSize, cfg.defaultOrderExpiration);

        for (uint256 i = 0; i < cfg.counterpartyTokens.length; i++) {
            _allowCounterpartyToken(offering, cfg.counterpartyTokens[i]);
        }

        return offeringId;
    }

    /**
     * @dev Allow an offering to be priced in `token`. Pass address(0) to enable native-ETH orders.
     * @notice Listing is per offering, not per contract: a fund priced in USDC and a token priced in
     * ETH live under one deployment without either inheriting the other's settlement assets.
     */
    function allowCounterpartyToken(uint256 offeringId, address token) external onlyRole(OPERATOR_ROLE) {
        Offering storage offering = _requireOffering(offeringId);
        if (offering.state == OfferingState.Closed) revert OfferingIsClosed();
        _allowCounterpartyToken(offering, token);
    }

    /**
     * @dev Stop new orders being priced in `token` on this offering.
     * @notice Orders already resting in that token are untouched and stay fillable — de-listing is
     * not a cancellation, and turning it into one would settle the book on the operator's schedule
     * rather than the makers'. To clear them, force-cancel with {adminCancelOrders}.
     */
    function disallowCounterpartyToken(uint256 offeringId, address token) external onlyRole(OPERATOR_ROLE) {
        _requireOffering(offeringId);
        if (!offeringCounterpartyTokens[offeringId][token]) revert TokenNotAllowed();

        offeringCounterpartyTokens[offeringId][token] = false;
        emit CounterpartyTokenDisallowed(offeringId, token);
    }

    /**
     * @dev Update an offering's fee schedule. ADMIN, because it is the venue's revenue lever.
     * @notice Resting orders keep the rates they were created with, so a change can never be applied
     * retroactively to a trade someone has already agreed to.
     */
    function setOfferingFees(uint256 offeringId, uint16 makerFeeBps_, uint16 takerFeeBps_)
        external
        onlyRole(ADMIN_ROLE)
    {
        Offering storage offering = _requireOffering(offeringId);
        if (offering.state == OfferingState.Closed) revert OfferingIsClosed();
        if (makerFeeBps_ > MAX_FEE_BPS || takerFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();

        offering.makerFeeBps = makerFeeBps_;
        offering.takerFeeBps = takerFeeBps_;
        emit OfferingFeesUpdated(offeringId, makerFeeBps_, takerFeeBps_);
    }

    /**
     * @dev Update an offering's order-size band and default expiry.
     * @param maxOrderSize_ 0 for no ceiling.
     * @param defaultOrderExpiration_ Seconds added to an order at creation; 0 for orders that never
     *        expire. Existing orders keep the expiry they were created with.
     */
    function setOfferingLimits(
        uint256 offeringId,
        uint256 minOrderSize_,
        uint256 maxOrderSize_,
        uint48 defaultOrderExpiration_
    ) external onlyRole(OPERATOR_ROLE) {
        Offering storage offering = _requireOffering(offeringId);
        if (offering.state == OfferingState.Closed) revert OfferingIsClosed();
        if (minOrderSize_ == 0) revert InvalidOrderSizeBounds();
        if (maxOrderSize_ != 0 && maxOrderSize_ < minOrderSize_) revert InvalidOrderSizeBounds();

        offering.minOrderSize = minOrderSize_;
        offering.maxOrderSize = maxOrderSize_;
        offering.defaultOrderExpiration = defaultOrderExpiration_;
        emit OfferingLimitsUpdated(offeringId, minOrderSize_, maxOrderSize_, defaultOrderExpiration_);
    }

    /**
     * @dev Halt one offering without touching the others — the reason a tenant-wide contract needs
     * more than a global pause. Cancelling and withdrawing keep working while an offering is paused.
     * @param paused True to halt new orders and fills, false to resume.
     */
    function setOfferingPaused(uint256 offeringId, bool paused) external onlyRole(OPERATOR_ROLE) {
        Offering storage offering = _requireOffering(offeringId);
        if (offering.state == OfferingState.Closed) revert OfferingIsClosed();

        OfferingState next = paused ? OfferingState.Paused : OfferingState.Active;
        if (offering.state == next) revert OfferingStateUnchanged();

        offering.state = next;
        emit OfferingStateChanged(offeringId, next);
    }

    // ============ Four-eyes: an offering's fee recipient ============

    /// @notice The id an approval must match to point this offering's fees at `recipient`.
    function offeringFeeRecipientProposalId(uint256 offeringId, address recipient) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.SetOfferingFeeRecipient, offeringId, recipient));
    }

    /**
     * @dev Propose redirecting an offering's fees. Four eyes because this is where the venue's
     * revenue lands: a single key able to change it can quietly reroute every future fee.
     */
    function proposeSetOfferingFeeRecipient(uint256 offeringId, address recipient) external onlyRole(ADMIN_ROLE) {
        _requireOffering(offeringId);
        if (recipient == address(0) || recipient == address(this)) revert InvalidFeeRecipient();

        _propose(offeringFeeRecipientProposalId(offeringId, recipient), ActionKind.SetOfferingFeeRecipient);
    }

    /// @dev Approve and execute the redirect.
    function approveSetOfferingFeeRecipient(uint256 offeringId, address recipient) external onlyRole(APPROVER_ROLE) {
        Offering storage offering = _requireOffering(offeringId);
        if (recipient == address(0) || recipient == address(this)) revert InvalidFeeRecipient();

        _approve(offeringFeeRecipientProposalId(offeringId, recipient), ActionKind.SetOfferingFeeRecipient);

        offering.feeRecipient = recipient;
        emit OfferingFeeRecipientUpdated(offeringId, recipient);
    }

    // ============ Four-eyes: closing an offering ============

    /// @notice The id an approval must match to close this offering for good.
    function closeOfferingProposalId(uint256 offeringId) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.CloseOffering, offeringId));
    }

    /**
     * @dev Propose closing an offering. The lifecycle is `Active -> Paused -> Closed`, and both of
     * the last step's preconditions are checked here and again at approval:
     *   - it must be PAUSED, so nobody can rest a new order between the proposal and the approval
     *     and brick the second signature — pausing is what makes the empty book stay empty;
     *   - its book must be EMPTY, because live orders still hold makers' escrow and standing
     *     allowances, and closing over them would strand both. Let the makers cancel, or clear the
     *     book with {adminCancelOrders}.
     */
    function proposeCloseOffering(uint256 offeringId) external onlyRole(ADMIN_ROLE) {
        Offering storage offering = _requireOffering(offeringId);
        if (offering.state == OfferingState.Closed) revert OfferingIsClosed();
        if (offering.state != OfferingState.Paused) revert OfferingNotPaused();
        if (offering.openOrderCount != 0) revert OfferingHasOpenOrders();

        _propose(closeOfferingProposalId(offeringId), ActionKind.CloseOffering);
    }

    /// @dev Approve and execute: the offering is closed for good and can never reopen.
    function approveCloseOffering(uint256 offeringId) external onlyRole(APPROVER_ROLE) {
        Offering storage offering = _requireOffering(offeringId);
        if (offering.state == OfferingState.Closed) revert OfferingIsClosed();
        if (offering.state != OfferingState.Paused) revert OfferingNotPaused();
        if (offering.openOrderCount != 0) revert OfferingHasOpenOrders();

        _approve(closeOfferingProposalId(offeringId), ActionKind.CloseOffering);

        offering.state = OfferingState.Closed;
        emit OfferingStateChanged(offeringId, OfferingState.Closed);
    }

    // ============ Trading ============

    /**
     * @dev Place an order on one offering's book.
     *
     * Funding is by ALLOWANCE, not deposit — approve this contract for your side of the trade and
     * keep custody until a taker fills. The one exception is a BUY order priced in ETH, which must
     * send `counterpartyTokenAmount + makerFee` as `msg.value` to be escrowed, because native ETH
     * cannot be pulled from an absent maker at fill time.
     *
     * For allowance-backed orders the balance/allowance check below is a soft PRECHECK only:
     * fillability is not guaranteed later, since the maker may move funds or revoke the allowance.
     * Use {isOrderFundable} to filter the book off-chain. An escrowed BUY+ETH order is always
     * fillable while it is live.
     *
     * @param offeringId Which offering's book to rest on.
     * @param orderType BUY (the maker buys base tokens) or SELL (the maker sells them).
     * @param counterpartyToken What the order is priced in; address(0) for native ETH.
     * @param baseTokenAmount Amount of the offering's base token to buy or sell.
     * @param counterpartyTokenAmount Amount of counterparty token to pay or receive in full.
     * @return orderId The id of the order created.
     */
    function createOrder(
        uint256 offeringId,
        OrderType orderType,
        address counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount
    ) external payable nonReentrant whenNotPaused returns (uint256 orderId) {
        address maker = _msgSender();
        if (msg.sender != maker && msg.value != 0) revert RelayedCallCannotCarryValue();

        Offering storage offering = _requireOffering(offeringId);
        if (offering.state != OfferingState.Active) revert OfferingNotActive();
        _requireEligible(offering, maker);
        _checkOrderTerms(offering, counterpartyToken, baseTokenAmount, counterpartyTokenAmount);

        // What the maker must put up: base tokens (SELL), or the counterparty amount plus the maker
        // fee (BUY). The maker bears the maker fee; the taker bears the taker fee at fill time.
        uint16 makerFeeBps_ = offering.makerFeeBps;
        (address fundToken, uint256 fundAmount) = _makerObligation(
            offering, orderType, counterpartyToken, baseTokenAmount, counterpartyTokenAmount, makerFeeBps_
        );
        uint256 escrow = _checkMakerFunding(maker, fundToken, fundAmount);

        uint48 expiresAt =
            offering.defaultOrderExpiration == 0 ? 0 : uint48(block.timestamp) + offering.defaultOrderExpiration;

        orderId = nextOrderId;
        nextOrderId++;

        if (escrow > 0) {
            ethEscrowed[orderId] = escrow;
            totalEthEscrowed += escrow;
        }

        _orders[orderId] = Order({
            id: orderId,
            offeringId: offeringId,
            maker: maker,
            orderType: orderType,
            isActive: true,
            makerFeeBps: makerFeeBps_,
            takerFeeBps: offering.takerFeeBps,
            expiresAt: expiresAt,
            counterpartyToken: counterpartyToken,
            createdAt: uint48(block.timestamp),
            baseTokenAmount: baseTokenAmount,
            counterpartyTokenAmount: counterpartyTokenAmount,
            filledAmount: 0
        });

        offering.openOrderCount++;
        _offeringOrderIds[offeringId].push(orderId);
        _makerOrderIds[maker].push(orderId);

        emit OrderCreated(
            orderId,
            offeringId,
            maker,
            orderType,
            counterpartyToken,
            baseTokenAmount,
            counterpartyTokenAmount,
            expiresAt
        );
    }

    /// @dev The terms an order must meet on its offering: a listed settlement asset, a size inside
    /// the band, and a price above zero.
    function _checkOrderTerms(
        Offering storage offering,
        address counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount
    ) private view {
        if (!offeringCounterpartyTokens[offering.offeringId][counterpartyToken]) {
            revert TokenNotAllowed();
        }
        if (baseTokenAmount < offering.minOrderSize) revert OrderSizeBelowMinimum();
        if (offering.maxOrderSize != 0 && baseTokenAmount > offering.maxOrderSize) revert OrderSizeAboveMaximum();
        if (counterpartyTokenAmount == 0) revert InvalidCounterpartyAmount();

        // Reject a zero-price order — base given away, and every fill of it would round to nothing
        // anyway. A 512-bit mulDiv so a large-but-legitimate pair of amounts cannot overflow here.
        if (Math.mulDiv(counterpartyTokenAmount, 1e18, baseTokenAmount) < _MIN_PRICE) revert PriceTooLow();
    }

    /**
     * @dev How the maker backs a fresh order. Native ETH (`fundToken == address(0)`) is the only
     * escrowed case and must arrive as `msg.value` exactly; anything else is allowance-backed, takes
     * no value, and is PRECHECKED — not guaranteed — against the maker's allowance and balance.
     * @return escrow What was deposited: `msg.value` for the ETH case, 0 otherwise.
     */
    function _checkMakerFunding(address maker, address fundToken, uint256 fundAmount)
        private
        view
        returns (uint256 escrow)
    {
        if (fundToken == address(0)) {
            if (msg.value != fundAmount) revert IncorrectEthAmount();
            return msg.value;
        }
        if (msg.value != 0) revert EthNotAccepted();
        if (IERC20(fundToken).allowance(maker, address(this)) < fundAmount) revert InsufficientAllowance();
        if (IERC20(fundToken).balanceOf(maker) < fundAmount) revert InsufficientBalance();
        return 0;
    }

    /**
     * @dev Fill an order, in whole or in part.
     *
     * Both legs move directly between maker and taker; the contract never takes custody. The taker
     * sends ETH only when buying base off a SELL order priced in ETH (excess is refunded inline).
     * When selling base into a BUY order priced in ETH, the taker is paid out of the maker's escrow.
     *
     * @param orderId The order to fill.
     * @param baseTokenAmount How much of the order's base-token size to take.
     */
    function fillOrder(uint256 orderId, uint256 baseTokenAmount) external payable nonReentrant whenNotPaused {
        address taker = _msgSender();
        if (msg.sender != taker && msg.value != 0) revert RelayedCallCannotCarryValue();

        Order storage order = _orders[orderId];
        if (!order.isActive) revert OrderNotActive();

        Offering storage offering = _offerings[order.offeringId];
        if (offering.state != OfferingState.Active) revert OfferingNotActive();

        // The gate is checked for BOTH sides at SETTLEMENT time: a maker whose verification lapsed
        // while their order rested stops trading, without anyone having to sweep the book first.
        _requireEligible(offering, taker);
        _requireEligible(offering, order.maker);
        _checkFillTerms(order, offering, taker, baseTokenAmount);

        Fill memory fill = _priceFill(order, offering, orderId, taker, baseTokenAmount);

        // The taker only ever SENDS ETH when buying base off a SELL order priced in ETH.
        if (fill.isEth && fill.isSell) {
            if (msg.value < fill.counterpartyTokenAmount + fill.takerFee) revert InsufficientEthSent();
        } else if (msg.value != 0) {
            revert EthNotAccepted();
        }

        // ---- Effects: every state write lands before any transfer or external call ----
        order.filledAmount += baseTokenAmount;
        bool nowComplete = order.filledAmount >= order.baseTokenAmount;
        if (nowComplete) {
            order.isActive = false;
            offering.openOrderCount--;
        }
        if (fill.isEth && !fill.isSell) {
            // Draw this fill's cost out of the maker's escrow: taker proceeds plus both fees.
            _drawEscrow(orderId, fill.counterpartyTokenAmount + fill.makerFee);
            // On the closing fill, return rounding dust so escrow accounting never strands ETH.
            if (nowComplete && ethEscrowed[orderId] > 0) {
                _refundEscrow(orderId, fill.maker);
            }
        }

        emit OrderFilled(
            orderId,
            order.offeringId,
            taker,
            baseTokenAmount,
            fill.counterpartyTokenAmount,
            fill.makerFee,
            fill.takerFee
        );

        _settle(fill);
    }

    /// @dev The terms a fill must meet: a live, unexpired order that is not the taker's own, for a
    /// non-zero amount inside what remains, and — unless it takes the remainder — at least the
    /// offering's minimum size.
    function _checkFillTerms(Order storage order, Offering storage offering, address taker, uint256 baseTokenAmount)
        private
        view
    {
        // slither-disable-next-line timestamp
        if (order.expiresAt != 0 && block.timestamp >= order.expiresAt) revert OrderExpired();
        if (order.maker == taker) revert CannotFillOwnOrder();
        if (baseTokenAmount == 0) revert InvalidFillAmount();

        uint256 remaining = order.baseTokenAmount - order.filledAmount;
        if (baseTokenAmount > remaining) revert ExceedsOrderSize();
        // A partial fill must be at least the offering's minimum order size, unless it takes the
        // remainder. Fees floor, so a fill that settles below `10_000 / feeBps` counterparty units
        // pays none — and without a floor on fill size an order could be taken in slices that each
        // pay nothing. The remainder is exempt so an order can always be closed out, whatever is
        // left of it.
        if (baseTokenAmount < offering.minOrderSize && baseTokenAmount != remaining) revert FillBelowMinimum();
    }

    /**
     * @dev Work out what a fill costs and who the parties are, at the order's snapshotted rates.
     * @notice Split out from {fillOrder} so the checks, the state writes and the transfers each
     * stay readable on their own — and so neither half is carrying a dozen locals.
     */
    function _priceFill(
        Order storage order,
        Offering storage offering,
        uint256 orderId,
        address taker,
        uint256 baseTokenAmount
    ) private view returns (Fill memory fill) {
        uint256 counterpartyTokenAmount = _counterpartyForFill(order, baseTokenAmount);
        // Reject a fill that settles to nothing: without this a taker could repeatedly take base
        // tokens while paying zero.
        if (counterpartyTokenAmount == 0) revert FillRoundsToZero();

        // Fees use the order's snapshotted rates. The maker always bears the maker fee and the taker
        // the taker fee, in both directions.
        fill = Fill({
            orderId: orderId,
            maker: order.maker,
            taker: taker,
            baseToken: offering.baseToken,
            counterpartyToken: order.counterpartyToken,
            feeRecipient: offering.feeRecipient,
            baseTokenAmount: baseTokenAmount,
            counterpartyTokenAmount: counterpartyTokenAmount,
            makerFee: (counterpartyTokenAmount * order.makerFeeBps) / BPS_DENOMINATOR,
            takerFee: (counterpartyTokenAmount * order.takerFeeBps) / BPS_DENOMINATOR,
            isSell: order.orderType == OrderType.SELL,
            isEth: order.counterpartyToken == address(0)
        });
    }

    /**
     * @dev Move both legs. ETH owed to resting parties (maker proceeds, fees) is CREDITED for later
     * withdrawal; only the active taker is paid inline, so a hostile maker or fee recipient cannot
     * block a trade. Called last, after every state write in {fillOrder}.
     */
    function _settle(Fill memory fill) private {
        uint256 totalFee = fill.makerFee + fill.takerFee;

        if (fill.isSell) {
            // SELL: the maker delivers base tokens and the taker pays the counterparty side.
            IERC20(fill.baseToken).safeTransferFrom(fill.maker, fill.taker, fill.baseTokenAmount);

            if (fill.isEth) {
                uint256 takerOwes = fill.counterpartyTokenAmount + fill.takerFee;
                _creditETH(fill.maker, fill.counterpartyTokenAmount - fill.makerFee);
                _creditETH(fill.feeRecipient, totalFee);
                if (msg.value > takerOwes) {
                    _sendETH(fill.taker, msg.value - takerOwes);
                }
            } else {
                IERC20 cpt = IERC20(fill.counterpartyToken);
                cpt.safeTransferFrom(fill.taker, fill.maker, fill.counterpartyTokenAmount - fill.makerFee);
                if (totalFee > 0) {
                    cpt.safeTransferFrom(fill.taker, fill.feeRecipient, totalFee);
                }
            }
        } else {
            // BUY: the maker takes base tokens and the taker delivers them.
            IERC20(fill.baseToken).safeTransferFrom(fill.taker, fill.maker, fill.baseTokenAmount);

            if (fill.isEth) {
                // Credit the fees (state) before paying the taker inline (CEI).
                _creditETH(fill.feeRecipient, totalFee);
                _sendETH(fill.taker, fill.counterpartyTokenAmount - fill.takerFee);
            } else {
                IERC20 cpt = IERC20(fill.counterpartyToken);
                cpt.safeTransferFrom(fill.maker, fill.taker, fill.counterpartyTokenAmount - fill.takerFee);
                if (totalFee > 0) {
                    cpt.safeTransferFrom(fill.maker, fill.feeRecipient, totalFee);
                }
            }
        }
    }

    /**
     * @dev Cancel your own order. An allowance-backed order simply goes inactive (no funds move); a
     * BUY+ETH order's unfilled escrow is credited back to the maker.
     * @notice Deliberately NOT pausable and NOT gated by the offering's state or its compliance
     * registry: a maker must always be able to take their order off the book and get their escrow
     * back, whatever else is going on.
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.maker != _msgSender()) revert NotOrderMaker();
        if (!order.isActive) revert OrderNotActive();

        _deactivate(order);
        emit OrderCancelled(orderId, order.offeringId, order.maker);

        _refundEscrow(orderId, order.maker);
    }

    /**
     * @dev Cancel several of your own orders. Orders that are not yours, or are already inactive,
     * are skipped rather than reverting the batch.
     */
    function batchCancelOrders(uint256[] calldata orderIds) external nonReentrant {
        if (orderIds.length == 0 || orderIds.length > MAX_BATCH_SIZE) revert InvalidBatchSize();
        address maker = _msgSender();

        uint256 released = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = _orders[orderIds[i]];
            if (order.maker == maker && order.isActive) {
                _deactivate(order);
                emit OrderCancelled(orderIds[i], order.offeringId, maker);
                released += _releaseEscrow(orderIds[i], maker);
            }
        }
        _moveEscrowToPending(released);
    }

    /**
     * @dev Clear expired orders off the book. Permissionless: expiry is deterministic and
     * ungameable, and the caller gains nothing — a BUY+ETH order's escrow is credited to its MAKER,
     * never to the caller.
     * @notice An underfunded but unexpired order is NOT cleanable by third parties, because
     * underfunding is transient; filter with {isOrderFundable} off-chain and let the maker cancel.
     * @return cleanedCount How many orders this call actually cleared.
     */
    function cleanupExpiredOrders(uint256[] calldata orderIds) external nonReentrant returns (uint256 cleanedCount) {
        if (orderIds.length == 0 || orderIds.length > MAX_BATCH_SIZE) revert InvalidBatchSize();

        uint256 released = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = _orders[orderIds[i]];
            // Expiry is the one thing block.timestamp is FOR here. A validator can shade it by a
            // few seconds, which shifts an order's expiry by a few seconds — nothing to gain.
            // slither-disable-next-line timestamp
            if (order.isActive && order.expiresAt != 0 && block.timestamp >= order.expiresAt) {
                address maker = order.maker;
                _deactivate(order);
                cleanedCount++;
                emit OrderCleanedUp(orderIds[i], order.offeringId, maker);
                released += _releaseEscrow(orderIds[i], maker);
            }
        }
        _moveEscrowToPending(released);

        emit OrdersCleanedUp(cleanedCount);
        return cleanedCount;
    }

    /**
     * @dev Withdraw your accrued ETH: maker proceeds, escrow refunds, or fees.
     * @notice Never pausable and never gated. Money already owed to someone is theirs, and no
     * compliance state or venue-wide halt may stand between them and it.
     */
    function withdraw() external nonReentrant {
        address account = _msgSender();
        uint256 amount = pendingWithdrawals[account];
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawals[account] = 0;
        totalPendingWithdrawals -= amount;

        emit Withdrawn(account, amount);
        _sendETH(account, amount);
    }

    // ============ Compliance force-cancel ============

    /**
     * @dev Force an order off the book — a de-listed or sanctioned maker whose resting orders must
     * stop trading now.
     * @notice The operator cannot take funds with this: an allowance-backed order simply goes
     * inactive, and a BUY+ETH order's escrow is credited to its MAKER. It carries its own event so
     * it is distinguishable from a maker-initiated cancel in any audit. Deliberate centralization:
     * hold {OPERATOR_ROLE} on a multisig.
     */
    function adminCancelOrder(uint256 orderId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        Order storage order = _orders[orderId];
        if (!order.isActive) revert OrderNotActive();

        address maker = order.maker;
        _deactivate(order);
        emit OrderAdminCancelled(orderId, maker, msg.sender);
        _refundEscrow(orderId, maker);
    }

    /// @dev Batch variant of {adminCancelOrder}. Orders already inactive are skipped.
    function adminCancelOrders(uint256[] calldata orderIds) external nonReentrant onlyRole(OPERATOR_ROLE) {
        if (orderIds.length == 0 || orderIds.length > MAX_BATCH_SIZE) revert InvalidBatchSize();
        address by = msg.sender;

        uint256 released = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = _orders[orderIds[i]];
            if (order.isActive) {
                address maker = order.maker;
                _deactivate(order);
                emit OrderAdminCancelled(orderIds[i], maker, by);
                released += _releaseEscrow(orderIds[i], maker);
            }
        }
        _moveEscrowToPending(released);
    }

    // ============ Four-eyes: trusted forwarder ============

    /// @notice The id an approval must match to point relaying at `forwarder_`.
    function forwarderProposalId(address forwarder_) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.SetTrustedForwarder, forwarder_));
    }

    /**
     * @dev Propose turning relaying on (a forwarder address) or off (address(0)). Four eyes because
     * a trusted forwarder can act as ANY address here — pointing it at the wrong contract is
     * equivalent to handing over every order and every pending withdrawal on the venue.
     */
    function proposeSetTrustedForwarder(address forwarder_) external onlyRole(ADMIN_ROLE) {
        _propose(forwarderProposalId(forwarder_), ActionKind.SetTrustedForwarder);
    }

    /// @dev Approve and execute the forwarder change.
    function approveSetTrustedForwarder(address forwarder_) external onlyRole(APPROVER_ROLE) {
        _approve(forwarderProposalId(forwarder_), ActionKind.SetTrustedForwarder);

        // address(0) is how relaying is switched OFF, so it is deliberately not rejected.
        // slither-disable-next-line missing-zero-check
        _trustedForwarder = forwarder_;
        emit TrustedForwarderUpdated(forwarder_);
    }

    // ============ Four-eyes: rescuing stray assets ============

    /// @notice The id an approval must match to rescue exactly this amount.
    function rescueProposalId(address token, address to, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.RescueAssets, token, to, amount));
    }

    /**
     * @dev Propose rescuing stray assets. Deliberately unpausable: the emergency path has to work in
     * an emergency.
     */
    function proposeRescueAssets(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidRecipient();

        _propose(rescueProposalId(token, to, amount), ActionKind.RescueAssets);
    }

    /**
     * @dev Approve and execute the rescue.
     * @notice Cannot touch reserved ETH, whoever approves: {rescuableAmount} is the balance minus
     * every wei of live escrow and every booked withdrawal, so the emergency path can only ever
     * reach what was forced in from outside the protocol. On a contract running many offerings at
     * once, an unbounded withdrawal is one mistake away from spending another book's escrow.
     *
     * ERC-20 is different and simpler: settlement moves both legs directly between maker and taker,
     * so this contract is never meant to hold any, and a balance that exists is by definition stray
     * — a mis-sent transfer — and fully rescuable.
     */
    function approveRescueAssets(address token, address to, uint256 amount)
        external
        onlyRole(APPROVER_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert InvalidRecipient();

        _approve(rescueProposalId(token, to, amount), ActionKind.RescueAssets);

        if (amount > rescuableAmount(token)) revert AmountIsReserved();

        emit AssetsRescued(token, to, amount);

        if (token == address(0)) {
            _sendETH(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice How much of `token` may be rescued right now: everything held that is not reserved for
     * a user. Always 0 for ETH under normal operation — the only way it is non-zero is ETH forced in
     * by `selfdestruct` or a block reward, since there is no `receive`/`fallback` here.
     */
    function rescuableAmount(address token) public view returns (uint256) {
        if (token == address(0)) {
            uint256 held = address(this).balance;
            uint256 reserved = totalEthEscrowed + totalPendingWithdrawals;
            if (held < reserved) revert ReserveAccountingBroken();
            return held - reserved;
        }
        return IERC20(token).balanceOf(address(this));
    }

    // ============ Proposals ============

    /// @dev Record a proposal under `proposalId`. Re-proposing overwrites, restarting the clock.
    /// `msg.sender`, never `_msgSender()`: see GOVERNANCE IS NEVER RELAYED below.
    function _propose(bytes32 proposalId, ActionKind kind) private {
        proposals[proposalId] = Proposal({proposer: msg.sender, proposedAt: uint64(block.timestamp)});
        emit ActionProposed(proposalId, kind, msg.sender);
    }

    /**
     * @dev Consume the proposal under `proposalId`, enforcing the two rules that make this four eyes
     * rather than two: the approver is not the proposer, and the proposal has not lapsed.
     */
    function _approve(bytes32 proposalId, ActionKind kind) private {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.proposer == address(0)) revert NoSuchProposal();
        // slither-disable-next-line timestamp
        if (block.timestamp > uint256(proposal.proposedAt) + PROPOSAL_TTL) revert ProposalExpired();
        if (proposal.proposer == msg.sender) revert ApproverMustNotBeProposer();

        delete proposals[proposalId];
        emit ActionApproved(proposalId, kind, msg.sender);
    }

    /// @dev Withdraw a pending proposal — its proposer changing their mind, or an admin.
    function cancelProposal(bytes32 proposalId) external {
        Proposal memory proposal = proposals[proposalId];
        // Slither taints the whole struct because `proposedAt` is a timestamp; these two lines
        // compare the proposer, not the time.
        // slither-disable-start timestamp
        if (proposal.proposer == address(0)) revert NoSuchProposal();
        if (proposal.proposer != msg.sender && !hasRole(ADMIN_ROLE, msg.sender)) revert NotAllowedToCancel();
        // slither-disable-end timestamp

        delete proposals[proposalId];
        emit ActionCancelled(proposalId, msg.sender);
    }

    // ============ Delayed role grants ============

    /// @notice The key a pending grant is filed under.
    function roleGrantId(bytes32 role, address account) public pure returns (bytes32) {
        return keccak256(abi.encode(role, account));
    }

    /**
     * @notice When a scheduled grant may be executed, and until when. Zero means there is no pending
     * grant for this pair.
     */
    function roleGrantWindow(bytes32 role, address account)
        public
        view
        returns (uint256 effectiveFrom, uint256 expiresAt)
    {
        uint64 scheduledAt = roleGrantScheduledAt[roleGrantId(role, account)];
        if (scheduledAt == 0) return (0, 0);

        effectiveFrom = uint256(scheduledAt) + ROLE_GRANT_DELAY;
        expiresAt = effectiveFrom + PROPOSAL_TTL;
    }

    /**
     * @dev Announce a role grant. It becomes executable after {ROLE_GRANT_DELAY} and lapses
     * {PROPOSAL_TTL} after that, so an old announcement cannot be dusted off months later.
     */
    function scheduleRoleGrant(bytes32 role, address account) external onlyRole(getRoleAdmin(role)) {
        if (account == address(0)) revert InvalidAccount();
        if (hasRole(role, account)) revert AlreadyHasRole();

        roleGrantScheduledAt[roleGrantId(role, account)] = uint64(block.timestamp);

        emit RoleGrantScheduled(role, account, block.timestamp + ROLE_GRANT_DELAY, msg.sender);
    }

    /**
     * @dev Cancel an announced grant before it takes effect.
     * @notice The guardian may cancel as well as the role's own admin — a veto that does not require
     * holding the key that scheduled it.
     */
    function cancelRoleGrant(bytes32 role, address account) external {
        if (!hasRole(getRoleAdmin(role), msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert NotAllowedToCancel();
        }

        bytes32 id = roleGrantId(role, account);
        if (roleGrantScheduledAt[id] == 0) revert NoPendingGrant();

        delete roleGrantScheduledAt[id];
        emit RoleGrantCancelled(role, account, msg.sender);
    }

    /**
     * @dev Grant a role that was announced at least {ROLE_GRANT_DELAY} ago.
     * @notice Overrides AccessControl's immediate grant. The initial roles set in {initialize}
     * bypass this — they are established before the contract can do anything, and there is nobody
     * yet for the delay to protect against. Revocation is untouched and stays immediate.
     */
    function grantRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable)
        onlyRole(getRoleAdmin(role))
    {
        (uint256 effectiveFrom, uint256 expiresAt) = roleGrantWindow(role, account);
        if (effectiveFrom == 0) revert GrantNotScheduled();
        // slither-disable-start timestamp
        if (block.timestamp < effectiveFrom) revert GrantStillWaiting();
        if (block.timestamp > expiresAt) revert GrantExpired();
        // slither-disable-end timestamp

        delete roleGrantScheduledAt[roleGrantId(role, account)];
        _grantRole(role, account);
    }

    // ============ Admin ============

    /// @dev Halt every offering at once. Cancelling and withdrawing keep working.
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ Views ============

    function getOffering(uint256 offeringId) external view returns (Offering memory) {
        return _offerings[offeringId];
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice The base token an order settles in — a property of its offering, not of the venue.
    function orderBaseToken(uint256 orderId) external view returns (address) {
        return _offerings[_orders[orderId].offeringId].baseToken;
    }

    /// @notice How much of an order is still available to fill. 0 once it is inactive or expired.
    function getRemainingAmount(uint256 orderId) public view returns (uint256) {
        Order storage order = _orders[orderId];
        if (!order.isActive) return 0;
        // slither-disable-next-line timestamp
        if (order.expiresAt != 0 && block.timestamp >= order.expiresAt) return 0;
        return order.baseTokenAmount - order.filledAmount;
    }

    function isOrderExpired(uint256 orderId) external view returns (bool) {
        Order storage order = _orders[orderId];
        if (!order.isActive || order.expiresAt == 0) return false;
        // slither-disable-next-line timestamp
        return block.timestamp >= order.expiresAt;
    }

    /**
     * @notice What a fill of `baseTokenAmount` would cost and pay, at the order's snapshotted rates.
     * @dev The rounding rule is visible here rather than buried in settlement: the counterparty
     * amount is rounded IN THE MAKER'S FAVOUR — up on a SELL, down on a BUY — so partial fills can
     * never bleed the resting side, and a BUY's escrow can never be drawn past what it holds.
     * @return counterpartyTokenAmount The gross counterparty amount this fill settles at.
     * @return makerFee What the maker pays the venue.
     * @return takerFee What the taker pays the venue.
     * @return takerNet The taker's side in counterparty units: what they PAY on a SELL
     *         (`counterparty + takerFee`), what they RECEIVE on a BUY (`counterparty - takerFee`).
     * @return makerNet The maker's side in counterparty units: what they RECEIVE on a SELL
     *         (`counterparty - makerFee`), what they PAY on a BUY (`counterparty + makerFee`).
     *         The base-token leg is `baseTokenAmount` itself in both directions.
     */
    function quoteFill(uint256 orderId, uint256 baseTokenAmount)
        external
        view
        returns (
            uint256 counterpartyTokenAmount,
            uint256 makerFee,
            uint256 takerFee,
            uint256 takerNet,
            uint256 makerNet
        )
    {
        Order storage order = _orders[orderId];
        if (baseTokenAmount == 0 || order.baseTokenAmount == 0) return (0, 0, 0, 0, 0);

        counterpartyTokenAmount = _counterpartyForFill(order, baseTokenAmount);
        makerFee = (counterpartyTokenAmount * order.makerFeeBps) / BPS_DENOMINATOR;
        takerFee = (counterpartyTokenAmount * order.takerFeeBps) / BPS_DENOMINATOR;

        if (order.orderType == OrderType.SELL) {
            takerNet = counterpartyTokenAmount + takerFee;
            makerNet = counterpartyTokenAmount - makerFee;
        } else {
            takerNet = counterpartyTokenAmount - takerFee;
            makerNet = counterpartyTokenAmount + makerFee;
        }
    }

    /**
     * @notice Whether an order can currently be filled for its whole remaining amount.
     * @dev Because orders are allowance-backed this is a TRANSIENT property: a maker can move funds
     * or revoke their approval at any time, and a false answer does not deactivate anything.
     * Frontends and relayers use it to filter the book. A BUY+ETH order is escrowed, so it is always
     * fundable while live.
     */
    function isOrderFundable(uint256 orderId) public view returns (bool) {
        Order storage order = _orders[orderId];
        if (!order.isActive) return false;
        // slither-disable-next-line timestamp
        if (order.expiresAt != 0 && block.timestamp >= order.expiresAt) return false;

        Offering storage offering = _offerings[order.offeringId];
        if (offering.state != OfferingState.Active) return false;
        if (!_isEligibleFor(offering, order.maker)) return false;

        (address token, uint256 need) = _makerObligationRemaining(order, offering);
        if (token == address(0)) {
            return ethEscrowed[orderId] >= need;
        }
        return
            IERC20(token).allowance(order.maker, address(this)) >= need && IERC20(token).balanceOf(order.maker) >= need;
    }

    /// @notice Whether `account` may currently trade this offering. True when it has no gate.
    function isEligibleToTrade(uint256 offeringId, address account) external view returns (bool) {
        return _isEligibleFor(_offerings[offeringId], account);
    }

    /// @notice How many orders have ever been placed on this offering.
    function offeringOrderCount(uint256 offeringId) external view returns (uint256) {
        return _offeringOrderIds[offeringId].length;
    }

    /// @notice How many orders `maker` has ever placed, across every offering.
    function makerOrderCount(address maker) external view returns (uint256) {
        return _makerOrderIds[maker].length;
    }

    /**
     * @notice One page of an offering's order ids, newest last.
     * @dev v1's equivalent walked every id the contract had ever issued. Under one contract per
     * tenant that would mean reading other offerings' books to answer a question about this one, so
     * ids are indexed per offering and per maker and the page is a slice, not a search.
     */
    function getOfferingOrders(uint256 offeringId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        return _page(_offeringOrderIds[offeringId], offset, limit);
    }

    /// @notice One page of a maker's order ids, across every offering, newest last.
    function getMakerOrders(address maker, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        return _page(_makerOrderIds[maker], offset, limit);
    }

    /**
     * @notice Walk an offering's book for orders that are live right now.
     * @dev BOUNDED on purpose. It examines at most `maxScan` ids starting at `cursor` and hands back
     * where it stopped, so the call costs what the caller allowed regardless of how long the book
     * has grown — the thing an unbounded "get all active orders" scan cannot promise once one
     * contract carries every offering a tenant has ever listed. Keep calling while `nextCursor` is
     * below {offeringOrderCount}.
     * @return orderIds The live orders found in this window.
     * @return nextCursor Where the next call should start.
     */
    function scanActiveOrders(uint256 offeringId, uint256 cursor, uint256 maxScan)
        external
        view
        returns (uint256[] memory orderIds, uint256 nextCursor)
    {
        if (maxScan == 0 || maxScan > MAX_PAGE_SIZE) revert InvalidPageSize();

        uint256[] storage ids = _offeringOrderIds[offeringId];
        uint256 end = cursor + maxScan;
        if (end > ids.length) end = ids.length;

        uint256[] memory found = new uint256[](end > cursor ? end - cursor : 0);
        uint256 count = 0;
        for (uint256 i = cursor; i < end; i++) {
            uint256 orderId = ids[i];
            Order storage order = _orders[orderId];
            // slither-disable-next-line timestamp
            if (order.isActive && (order.expiresAt == 0 || block.timestamp < order.expiresAt)) {
                found[count] = orderId;
                count++;
            }
        }

        orderIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = found[i];
        }
        return (orderIds, end);
    }

    function trustedForwarder() public view virtual returns (address) {
        return _trustedForwarder;
    }

    function isTrustedForwarder(address forwarder) public view virtual returns (bool) {
        return forwarder != address(0) && forwarder == _trustedForwarder;
    }

    // ============ Internals ============

    function _requireOffering(uint256 offeringId) private view returns (Offering storage offering) {
        offering = _offerings[offeringId];
        if (!offering.initialized) revert OfferingNotFound();
    }

    function _allowCounterpartyToken(Offering storage offering, address token) private {
        if (token == offering.baseToken) revert CounterpartyIsBaseToken();
        // address(0) is native ETH; anything else has to be a contract, or the first order priced
        // in it would revert with no name somewhere inside the allowance precheck.
        if (token != address(0) && token.code.length == 0) revert InvalidCounterpartyToken();
        uint256 offeringId = offering.offeringId;
        if (offeringCounterpartyTokens[offeringId][token]) revert TokenAlreadyAllowed();

        offeringCounterpartyTokens[offeringId][token] = true;
        emit CounterpartyTokenAllowed(offeringId, token);
    }

    /**
     * @dev Enforce the offering's compliance gate, if it has one. Fails CLOSED: a registry that
     * reverts or cannot be reached blocks the trade — for a gated offering, "unknown" must never
     * mean "may trade".
     */
    function _requireEligible(Offering storage offering, address account) private view {
        address registry = offering.eligibilityRegistry;
        if (registry == address(0)) return;

        (bool answered, bool eligible) = _queryEligibility(registry, account);
        if (!answered) revert EligibilityCheckUnavailable();
        if (!eligible) revert NotEligible();
    }

    /// @dev Non-reverting twin of {_requireEligible}, for views.
    function _isEligibleFor(Offering storage offering, address account) private view returns (bool) {
        address registry = offering.eligibilityRegistry;
        if (registry == address(0)) return true;

        (bool answered, bool eligible) = _queryEligibility(registry, account);
        return answered && eligible;
    }

    /**
     * @dev Ask a gate about an address, distinguishing "said no" from "did not answer".
     *
     * A low-level staticcall rather than `try`/`catch`, because `try` does not catch a failure to
     * DECODE the reply: a registry that returns nothing — or an address with no code at all, which
     * a mistyped configuration produces — would revert anonymously somewhere inside settlement
     * instead of failing with a named error at listing time. Checking the reply's shape ourselves
     * turns every one of those into {RegistryNotAnswering} or {EligibilityCheckUnavailable}.
     *
     * Either way the outcome is the same and is the one that matters: a gate that cannot answer
     * never means "may trade".
     */
    function _queryEligibility(address registry, address account) private view returns (bool answered, bool eligible) {
        // A low-level call on purpose: see the note above about `try` and undecodable replies.
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) =
            registry.staticcall(abi.encodeCall(IEligibilityRegistry.isEligible, (account)));
        if (!success || data.length < 32) return (false, false);
        return (true, abi.decode(data, (bool)));
    }

    /// @dev Take an order off the book and off its offering's live count.
    function _deactivate(Order storage order) private {
        order.isActive = false;
        _offerings[order.offeringId].openOrderCount--;
    }

    /// @dev Spend `amount` of an order's escrow, keeping the contract-wide reserve in step.
    function _drawEscrow(uint256 orderId, uint256 amount) private {
        ethEscrowed[orderId] -= amount;
        totalEthEscrowed -= amount;
    }

    /**
     * @dev Return a BUY+ETH order's unfilled escrow to its maker and zero the accounting. A no-op
     * for every other order kind, since nothing is ever escrowed for them. Callers must already have
     * deactivated the order; the balance is zeroed before the credit is booked.
     */
    function _refundEscrow(uint256 orderId, address maker) private {
        _moveEscrowToPending(_releaseEscrow(orderId, maker));
    }

    /**
     * @dev The per-order half of a refund: zero the escrow, book the maker's claim, emit. Leaves the
     * two contract-wide totals alone so a batch can settle them once — see {_moveEscrowToPending}.
     * Makes no external call, so nothing can observe the totals while they are out of step.
     * @return amount What was released; 0 for an order that held no escrow.
     */
    function _releaseEscrow(uint256 orderId, address maker) private returns (uint256 amount) {
        amount = ethEscrowed[orderId];
        if (amount == 0) return 0;

        ethEscrowed[orderId] = 0;
        pendingWithdrawals[maker] += amount;

        emit EthEscrowRefunded(orderId, maker, amount);
        emit EthCredited(maker, amount);
    }

    /**
     * @dev The contract-wide half of a refund: escrow that became a claim moves from one reserve
     * total to the other. The balance is unchanged, so the reserve property is untouched; only
     * which bucket owns the wei changes. Batches call this once with the sum instead of twice per
     * order.
     */
    function _moveEscrowToPending(uint256 amount) private {
        if (amount == 0) return;
        totalEthEscrowed -= amount;
        totalPendingWithdrawals += amount;
    }

    /**
     * @dev Book ETH as claimable for `to` (pull-payment). Never reverts on a hostile recipient, so a
     * maker or fee recipient that cannot receive ETH can never block settlement or a cancel.
     */
    function _creditETH(address to, uint256 amount) private {
        if (amount == 0) return;

        pendingWithdrawals[to] += amount;
        totalPendingWithdrawals += amount;
        emit EthCredited(to, amount);
    }

    /**
     * @dev Send native ETH to the ACTIVE caller, reverting loudly on failure. Used only for inline
     * payouts to the caller (taker proceeds, excess refund) and for an approved rescue; resting
     * parties are credited instead.
     */
    function _sendETH(address to, uint256 amount) private {
        if (amount == 0) return;

        // `call` rather than `transfer`: the 2300-gas stipend would refuse legitimate smart-wallet
        // takers. Reentrancy is handled by the guard on every caller, not by starving the callee.
        // slither-disable-next-line low-level-calls
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }

    /**
     * @dev What a fill of `baseAmount` settles at, rounded in the MAKER'S favour: up when the maker
     * is selling (they receive it) and down when the maker is buying (they pay it).
     *
     * Rounding down on a BUY is not a preference but a requirement: the escrow holds exactly
     * `counterpartyTokenAmount + makerFee`, and since a sum of rounded-down parts never exceeds the
     * rounded-down whole, no sequence of partial fills can draw past it. Rounding up on a SELL costs
     * the taker at most one unit of the counterparty asset per fill and stops a maker being bled by
     * a long tail of small ones. That unit is immaterial at any sane decimals — and an offering
     * whose `minOrderSize` is small enough for it to matter is a misconfiguration, which is what
     * the size band exists to prevent. Either way the taker sees the exact figure in {quoteFill}
     * before they commit.
     */
    function _counterpartyForFill(Order storage order, uint256 baseAmount) private view returns (uint256) {
        return Math.mulDiv(
            baseAmount,
            order.counterpartyTokenAmount,
            order.baseTokenAmount,
            order.orderType == OrderType.SELL ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
    }

    /**
     * @dev What a maker must put up to fully back a fresh order: base tokens (SELL), or the
     * counterparty amount plus the maker fee (BUY). If `token` is address(0) the obligation is met
     * by escrowing `amount` as `msg.value`; otherwise by an allowance.
     */
    function _makerObligation(
        Offering storage offering,
        OrderType orderType,
        address counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount,
        uint16 makerFeeBps_
    ) private view returns (address token, uint256 amount) {
        if (orderType == OrderType.SELL) {
            return (offering.baseToken, baseTokenAmount);
        }
        uint256 makerFeeDeposit = (counterpartyTokenAmount * makerFeeBps_) / BPS_DENOMINATOR;
        return (counterpartyToken, counterpartyTokenAmount + makerFeeDeposit);
    }

    /// @dev {_makerObligation} for an order's REMAINING unfilled part, at its snapshotted fee rate.
    function _makerObligationRemaining(Order storage order, Offering storage offering)
        private
        view
        returns (address token, uint256 amount)
    {
        uint256 remainingBase = order.baseTokenAmount - order.filledAmount;
        if (order.orderType == OrderType.SELL) {
            return (offering.baseToken, remainingBase);
        }
        uint256 remainingCounterparty =
            Math.mulDiv(remainingBase, order.counterpartyTokenAmount, order.baseTokenAmount, Math.Rounding.Floor);
        uint256 makerFeeRemaining = (remainingCounterparty * order.makerFeeBps) / BPS_DENOMINATOR;
        return (order.counterpartyToken, remainingCounterparty + makerFeeRemaining);
    }

    /// @dev One page of an id index, with the index's full length so a caller can size the next call.
    function _page(uint256[] storage ids, uint256 offset, uint256 limit)
        private
        view
        returns (uint256[] memory page, uint256 total)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPageSize();

        total = ids.length;
        if (offset >= total) return (new uint256[](0), total);

        uint256 size = total - offset;
        if (size > limit) size = limit;

        page = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            page[i] = ids[offset + i];
        }
    }

    // ============ ERC-2771 context ============
    //
    // The forwarder lives in storage, not in an immutable, so one implementation can serve tenants
    // who pay their users' gas and tenants who do not. A relayed call may never carry value: the
    // ETH would be the forwarder's, not the sender's, and {createOrder} and {fillOrder} refuse it.
    //
    // GOVERNANCE IS NEVER RELAYED. Relaying exists so a USER can trade without holding gas. It must
    // not extend to the keys that run the venue: a forwarder that could act as the approver would
    // hold every role at once, and four eyes would be two. So every role check, every proposal and
    // every approval reads `msg.sender` directly — a privileged call has to come from the key
    // itself. `_msgSender()` is used only where the actor is a trader.

    /// @dev Role checks see the real caller, never a forwarded one.
    function _checkRole(bytes32 role) internal view virtual override(AccessControlUpgradeable) {
        _checkRole(role, msg.sender);
    }

    function _msgSender() internal view virtual override(ContextUpgradeable) returns (address) {
        uint256 calldataLength = msg.data.length;
        if (calldataLength >= _CONTEXT_SUFFIX_LENGTH && isTrustedForwarder(msg.sender)) {
            unchecked {
                return address(bytes20(msg.data[calldataLength - _CONTEXT_SUFFIX_LENGTH:]));
            }
        }
        return super._msgSender();
    }

    // `_msgData` and `_contextSuffixLength` have no caller in this contract today. They are kept
    // because they are the other half of `_msgSender`: anything that later reads `_msgData()` — an
    // upgrade adding Multicall, say — must see the same trimmed calldata, or a relayed batch would
    // carry the forwarder's suffix into every sub-call.
    // slither-disable-next-line dead-code
    function _msgData() internal view virtual override(ContextUpgradeable) returns (bytes calldata) {
        uint256 calldataLength = msg.data.length;
        if (calldataLength >= _CONTEXT_SUFFIX_LENGTH && isTrustedForwarder(msg.sender)) {
            unchecked {
                return msg.data[:calldataLength - _CONTEXT_SUFFIX_LENGTH];
            }
        }
        return super._msgData();
    }

    // slither-disable-next-line dead-code
    function _contextSuffixLength() internal view virtual override(ContextUpgradeable) returns (uint256) {
        return _CONTEXT_SUFFIX_LENGTH;
    }

    /**
     * @dev Deliberately NO `receive` or `fallback`. Every wei here arrives through {createOrder} or
     * {fillOrder}, which account for it, so a plain transfer reverts rather than becoming money
     * nobody has a claim on.
     */
}
