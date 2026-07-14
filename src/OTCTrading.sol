// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OTCTrading
 * @dev Over-The-Counter trading contract for ERC20 tokens with configurable fees, whitelist, and counterparty tokens
 *
 * @notice IMPORTANT: This contract does NOT support fee-on-transfer tokens.
 * Fee-on-transfer tokens (tokens that charge a fee on transfer like PAXG, some USDT implementations)
 * will cause accounting issues because the contract receives less tokens than expected.
 * Only standard ERC20 tokens should be used as counterparty tokens.
 *
 * @notice CUSTODY MODEL: orders are backed by an ALLOWANCE, not a deposit. Makers keep their funds
 * in their own wallet and both legs settle atomically at fill time via `transferFrom`. There is one
 * exception: a BUY order priced in native ETH must ESCROW `counterpartyAmount + makerFee` at
 * creation, because an allowance can pull ERC20 at a later fill but nothing can pull native ETH from
 * a maker who is not present in the taker's transaction. Escrow is tracked per order in
 * {ethEscrowed} and the unfilled remainder is credited back to the maker on cancel/cleanup.
 *
 * @notice ETH PAYOUTS USE PULL PAYMENTS. Amounts owed to a resting party (a maker's ETH proceeds or
 * escrow refund, and the fee recipient's fees) are booked into {pendingWithdrawals} and claimed
 * later via {withdraw}; they are never pushed. This means a maker or fee recipient that cannot
 * receive ETH can never block settlement, a cancel, or an admin/compliance force-cancel — they just
 * accrue a claimable balance. Only the active caller (the taker) is paid inline. See
 * NONCUSTODIAL_DESIGN.md. Invariant: `address(this).balance == Σ ethEscrowed + Σ pendingWithdrawals`.
 *
 * @notice UPGRADEABLE (UUPS). Because users grant this contract an allowance (and BUY+ETH makers
 * escrow ETH in it), whoever holds UPGRADER_ROLE can in principle change the settlement code and
 * move approved/escrowed balances. That role MUST be held by a Timelock + multisig so any upgrade is
 * publicly visible for the delay window, letting users revoke approvals and exit before it lands.
 * Storage is append-only across upgrades (enforced by the OpenZeppelin upgrades validator).
 */
contract OTCTrading is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Trading parameters
    uint256 public makerFeeBps; // Maker fee in basis points (1 bps = 0.01%)
    uint256 public takerFeeBps; // Taker fee in basis points
    uint256 public minOrderSize; // Minimum order size
    uint256 public maxOrderSize; // Maximum order size (0 = no limit)
    bool public requireWhitelist; // Whether whitelist is required for trading
    uint256 public defaultOrderExpiration; // Default order expiration time in seconds (0 = no expiration)

    // Token addresses
    address public baseToken; // The ERC20 token being traded (from ERC20 folder)
    address public feeRecipient; // Address that receives trading fees

    // Allowed counterparty tokens (e.g., USDC)
    mapping(address => bool) public allowedCounterpartyTokens;

    // Whitelist management
    mapping(address => bool) public whitelist;

    // Order type enum
    enum OrderType {
        BUY, // Buying base tokens with counterparty tokens
        SELL // Selling base tokens for counterparty tokens
    }

    // Order structure
    struct Order {
        uint256 id;
        address maker;
        OrderType orderType; // BUY or SELL
        address counterpartyToken; // Token to receive (e.g., USDC)
        uint256 baseTokenAmount; // Amount of base token (to buy or sell)
        uint256 counterpartyTokenAmount; // Amount of counterparty token (to pay or receive)
        uint256 filledAmount; // Amount already filled (in base token units)
        bool isActive;
        uint256 createdAt;
        uint256 expiresAt; // Expiration timestamp (0 = no expiration)
        // Fee rates snapshotted at creation so later admin fee changes cannot be
        // applied retroactively to orders that are already on the book.
        uint256 makerFeeBps;
        uint256 takerFeeBps;
    }

    // Order management
    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;
    mapping(address => uint256[]) public userOrders; // User's order IDs

    // Native ETH escrowed for a BUY+ETH order (zero for every other order kind). There is no
    // receive()/fallback, so a raw transfer to this contract reverts: the only ETH ever held backs
    // either live escrow or an unclaimed withdrawal.
    mapping(uint256 => uint256) public ethEscrowed;

    // Claimable ETH booked for a party (maker proceeds/refunds, fee-recipient fees). Pull-payment:
    // the owner calls {withdraw}. Appended after ethEscrowed to keep the storage layout append-only.
    mapping(address => uint256) public pendingWithdrawals;

    // Events
    event OrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        OrderType orderType,
        address indexed counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount,
        uint256 makerFee,
        uint256 takerFee
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker);
    event OrderAdminCancelled(uint256 indexed orderId, address indexed maker, address indexed admin);
    event EthEscrowRefunded(uint256 indexed orderId, address indexed maker, uint256 amount);
    event EthCredited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event CounterpartyTokenAdded(address indexed token);
    event CounterpartyTokenRemoved(address indexed token);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
    event FeesUpdated(uint256 makerFeeBps, uint256 takerFeeBps);
    event MinOrderSizeUpdated(uint256 minOrderSize);
    event WhitelistRequirementUpdated(bool requireWhitelist);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event MaxOrderSizeUpdated(uint256 maxOrderSize);
    event DefaultOrderExpirationUpdated(uint256 defaultOrderExpiration);
    event OrdersCleanedUp(uint256[] orderIds);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the OTC Trading contract
     * @param _baseToken Address of the base ERC20 token to trade
     * @param _defaultCounterpartyToken Default counterparty token (e.g., USDC)
     * @param _feeRecipient Address that receives trading fees
     * @param _admin Admin address (also granted UPGRADER_ROLE; move it to a Timelock + multisig)
     * @param _makerFeeBps Initial maker fee in basis points (max 1000 = 10%)
     * @param _takerFeeBps Initial taker fee in basis points (max 1000 = 10%)
     * @param _minOrderSize Initial minimum order size (must be > 0 and <= _maxOrderSize if max is set)
     * @param _maxOrderSize Initial maximum order size (0 = no limit, must be >= _minOrderSize if set)
     * @param _defaultOrderExpiration Default order expiration time in seconds (0 = no expiration)
     * @param _requireWhitelist Whether whitelist is required for trading
     */
    function initialize(
        address _baseToken,
        address _defaultCounterpartyToken,
        address _feeRecipient,
        address _admin,
        uint256 _makerFeeBps,
        uint256 _takerFeeBps,
        uint256 _minOrderSize,
        uint256 _maxOrderSize,
        uint256 _defaultOrderExpiration,
        bool _requireWhitelist
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();

        require(_baseToken != address(0), "OTCTrading: invalid base token");
        require(_defaultCounterpartyToken != address(0), "OTCTrading: invalid counterparty token");
        require(_defaultCounterpartyToken != _baseToken, "OTCTrading: counterparty is base token");
        require(_feeRecipient != address(0), "OTCTrading: invalid fee recipient");
        require(_admin != address(0), "OTCTrading: invalid admin");

        // Validate economic parameters (mirror admin setters)
        require(_makerFeeBps <= 1000, "OTCTrading: maker fee too high"); // Max 10%
        require(_takerFeeBps <= 1000, "OTCTrading: taker fee too high"); // Max 10%
        require(_minOrderSize > 0, "OTCTrading: invalid min order size");
        require(_maxOrderSize == 0 || _maxOrderSize >= _minOrderSize, "OTCTrading: max below min");

        baseToken = _baseToken;
        feeRecipient = _feeRecipient;

        // Set initial fees and trading parameters
        makerFeeBps = _makerFeeBps;
        takerFeeBps = _takerFeeBps;
        minOrderSize = _minOrderSize;
        maxOrderSize = _maxOrderSize;
        requireWhitelist = _requireWhitelist;
        defaultOrderExpiration = _defaultOrderExpiration;

        // Add default counterparty token
        allowedCounterpartyTokens[_defaultCounterpartyToken] = true;
        emit CounterpartyTokenAdded(_defaultCounterpartyToken);

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        nextOrderId = 1;
    }

    /**
     * @dev Authorize a UUPS implementation upgrade. Restricted to UPGRADER_ROLE, which MUST be a
     * Timelock + multisig so upgrades are time-delayed and publicly visible: users hold standing
     * allowances (and BUY+ETH escrow) here and need a window to exit before a new implementation
     * takes effect.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Admin Functions ============

    /**
     * @dev Add an allowed counterparty token (can be ERC20 or address(0) for ETH)
     * @param token Address of the counterparty token (address(0) for ETH)
     */
    function addCounterpartyToken(address token) external onlyRole(ADMIN_ROLE) {
        require(token != baseToken, "OTCTrading: counterparty is base token");
        require(!allowedCounterpartyTokens[token], "OTCTrading: token already allowed");
        allowedCounterpartyTokens[token] = true;
        emit CounterpartyTokenAdded(token);
    }

    /**
     * @dev Remove an allowed counterparty token
     * @param token Address of the counterparty token
     */
    function removeCounterpartyToken(address token) external onlyRole(ADMIN_ROLE) {
        require(allowedCounterpartyTokens[token], "OTCTrading: token not allowed");
        allowedCounterpartyTokens[token] = false;
        emit CounterpartyTokenRemoved(token);
    }

    /**
     * @dev Update maker and taker fees
     * @param _makerFeeBps New maker fee in basis points
     * @param _takerFeeBps New taker fee in basis points
     */
    function updateFees(uint256 _makerFeeBps, uint256 _takerFeeBps) external onlyRole(ADMIN_ROLE) {
        require(_makerFeeBps <= 1000, "OTCTrading: maker fee too high"); // Max 10%
        require(_takerFeeBps <= 1000, "OTCTrading: taker fee too high"); // Max 10%
        makerFeeBps = _makerFeeBps;
        takerFeeBps = _takerFeeBps;
        emit FeesUpdated(_makerFeeBps, _takerFeeBps);
    }

    /**
     * @dev Update minimum order size
     * @param _minOrderSize New minimum order size
     */
    function updateMinOrderSize(uint256 _minOrderSize) external onlyRole(ADMIN_ROLE) {
        require(_minOrderSize > 0, "OTCTrading: invalid min order size");
        require(maxOrderSize == 0 || _minOrderSize <= maxOrderSize, "OTCTrading: min exceeds max");
        minOrderSize = _minOrderSize;
        emit MinOrderSizeUpdated(_minOrderSize);
    }

    /**
     * @dev Update maximum order size (0 = no limit)
     * @param _maxOrderSize New maximum order size
     */
    function updateMaxOrderSize(uint256 _maxOrderSize) external onlyRole(ADMIN_ROLE) {
        require(_maxOrderSize == 0 || _maxOrderSize >= minOrderSize, "OTCTrading: max below min");
        maxOrderSize = _maxOrderSize;
        emit MaxOrderSizeUpdated(_maxOrderSize);
    }

    /**
     * @dev Update default order expiration time
     * @param _defaultOrderExpiration Default expiration time in seconds (0 = no expiration)
     */
    function updateDefaultOrderExpiration(uint256 _defaultOrderExpiration) external onlyRole(ADMIN_ROLE) {
        defaultOrderExpiration = _defaultOrderExpiration;
        emit DefaultOrderExpirationUpdated(_defaultOrderExpiration);
    }

    /**
     * @dev Update whitelist requirement
     * @param _requireWhitelist Whether whitelist is required
     */
    function updateWhitelistRequirement(bool _requireWhitelist) external onlyRole(ADMIN_ROLE) {
        requireWhitelist = _requireWhitelist;
        emit WhitelistRequirementUpdated(_requireWhitelist);
    }

    /**
     * @dev Add address to whitelist
     * @param account Address to add
     */
    function addToWhitelist(address account) external onlyRole(ADMIN_ROLE) {
        require(account != address(0), "OTCTrading: invalid account");
        require(!whitelist[account], "OTCTrading: already whitelisted");
        whitelist[account] = true;
        emit WhitelistAdded(account);
    }

    /**
     * @dev Remove address from whitelist
     * @param account Address to remove
     */
    function removeFromWhitelist(address account) external onlyRole(ADMIN_ROLE) {
        require(whitelist[account], "OTCTrading: not whitelisted");
        whitelist[account] = false;
        emit WhitelistRemoved(account);
    }

    /**
     * @dev Batch add addresses to whitelist
     * @param accounts Array of addresses to add
     */
    function batchAddToWhitelist(address[] calldata accounts) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "OTCTrading: invalid account");
            if (!whitelist[accounts[i]]) {
                whitelist[accounts[i]] = true;
                emit WhitelistAdded(accounts[i]);
            }
        }
    }

    /**
     * @dev Batch remove addresses from whitelist
     * @param accounts Array of addresses to remove
     */
    function batchRemoveFromWhitelist(address[] calldata accounts) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (whitelist[accounts[i]]) {
                whitelist[accounts[i]] = false;
                emit WhitelistRemoved(accounts[i]);
            }
        }
    }

    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function updateFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        require(_feeRecipient != address(0), "OTCTrading: invalid fee recipient");
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /**
     * @dev Pause trading
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause trading
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Admin/compliance force-cancel of an active order (e.g. a de-whitelisted or sanctioned
     * maker whose resting orders must come off the book). The admin cannot take funds: an
     * allowance-backed order simply goes inactive, and a BUY+ETH order's escrow is returned to its
     * MAKER. Emitted with a distinct event so it is auditable and distinguishable from a
     * maker-initiated cancel. Deliberate centralization power: hold ADMIN_ROLE behind a
     * multisig/timelock.
     * @param orderId ID of the order to force-cancel
     */
    function adminCancelOrder(uint256 orderId) external nonReentrant onlyRole(ADMIN_ROLE) {
        Order storage order = orders[orderId];
        require(order.isActive, "OTCTrading: order not active");
        address maker = order.maker;
        order.isActive = false;
        emit OrderAdminCancelled(orderId, maker, msg.sender);
        _refundEscrow(orderId, maker);
    }

    /**
     * @dev Batch variant of {adminCancelOrder}. Skips orders that are already inactive.
     * @param orderIds Array of order IDs to force-cancel
     */
    function adminCancelOrders(uint256[] calldata orderIds) external nonReentrant onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (order.isActive) {
                address maker = order.maker;
                order.isActive = false;
                emit OrderAdminCancelled(orderIds[i], maker, msg.sender);
                _refundEscrow(orderIds[i], maker);
            }
        }
    }

    // ============ Trading Functions ============

    /**
     * @dev Helper function to check if token is ETH
     */
    function _isETH(address token) private pure returns (bool) {
        return token == address(0);
    }

    /**
     * @dev Create a new order (buy or sell)
     *
     * Funding is by ALLOWANCE, not deposit — approve this contract for your side of the trade and
     * keep custody until a taker fills. The one exception is a BUY order priced in ETH, which must
     * send `counterpartyTokenAmount + makerFee` as msg.value to be escrowed (native ETH cannot be
     * pulled from an absent maker at fill time).
     *
     * For allowance-backed orders the balance/allowance check below is a soft precheck only:
     * fillability is NOT guaranteed later, since the maker may move funds or revoke the allowance.
     * Use {isOrderFundable} to filter the book off-chain. An escrowed BUY+ETH order is always fillable.
     *
     * @param orderType Type of order: BUY (buying base tokens) or SELL (selling base tokens)
     * @param counterpartyToken Address of the counterparty token (address(0) for ETH, or ERC20 token)
     * @param baseTokenAmount Amount of base token to buy/sell
     * @param counterpartyTokenAmount Amount of counterparty token to pay/receive
     * @return orderId The ID of the created order
     */
    function createOrder(
        OrderType orderType,
        address counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount
    ) external payable nonReentrant whenNotPaused returns (uint256 orderId) {
        // Check whitelist requirement
        if (requireWhitelist) {
            require(whitelist[msg.sender], "OTCTrading: not whitelisted");
        }

        // Validate inputs
        require(allowedCounterpartyTokens[counterpartyToken], "OTCTrading: counterparty token not allowed");
        require(baseTokenAmount >= minOrderSize, "OTCTrading: order size below minimum");
        require(maxOrderSize == 0 || baseTokenAmount <= maxOrderSize, "OTCTrading: order size above maximum");
        require(counterpartyTokenAmount > 0, "OTCTrading: invalid counterparty amount");

        // Price validation: prevent zero-price or extremely skewed prices
        // Price must be reasonable (not zero and not more than 10^18 ratio)
        require(counterpartyTokenAmount * 1e18 / baseTokenAmount >= 1, "OTCTrading: price too low");
        require(counterpartyTokenAmount * 1e18 / baseTokenAmount <= 1e36, "OTCTrading: price too high");

        // What the maker must put up: base tokens (SELL), or the counterparty amount plus the maker
        // fee (BUY). The maker bears the maker fee; the taker bears the taker fee at fill time.
        (address fundToken, uint256 fundAmount) =
            _makerObligation(orderType, counterpartyToken, baseTokenAmount, counterpartyTokenAmount);

        uint256 escrow = 0;
        if (orderType == OrderType.BUY && _isETH(counterpartyToken)) {
            // Only escrowed case: ETH must be pre-funded, it cannot be pulled at fill time.
            require(msg.value == fundAmount, "OTCTrading: incorrect ETH amount");
            escrow = msg.value;
        } else {
            // Allowance-backed: nothing is deposited, so no ETH may be sent.
            require(msg.value == 0, "OTCTrading: ETH not needed");
            require(IERC20(fundToken).allowance(msg.sender, address(this)) >= fundAmount, "OTCTrading: approve first");
            require(IERC20(fundToken).balanceOf(msg.sender) >= fundAmount, "OTCTrading: insufficient balance");
        }

        // Calculate expiration
        uint256 expirationTime = 0;
        if (defaultOrderExpiration > 0) {
            expirationTime = block.timestamp + defaultOrderExpiration;
        }

        // Create order
        orderId = nextOrderId++;
        if (escrow > 0) {
            ethEscrowed[orderId] = escrow;
        }
        orders[orderId] = Order({
            id: orderId,
            maker: msg.sender,
            orderType: orderType,
            counterpartyToken: counterpartyToken,
            baseTokenAmount: baseTokenAmount,
            counterpartyTokenAmount: counterpartyTokenAmount,
            filledAmount: 0,
            isActive: true,
            createdAt: block.timestamp,
            expiresAt: expirationTime,
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps
        });

        userOrders[msg.sender].push(orderId);

        emit OrderCreated(orderId, msg.sender, orderType, counterpartyToken, baseTokenAmount, counterpartyTokenAmount);
    }

    /**
     * @dev Fill an order (partially or fully)
     *
     * Both legs move directly between maker and taker; the contract never takes custody. The taker
     * sends ETH only when buying base off a SELL order priced in ETH (excess is refunded). When
     * selling base into a BUY order priced in ETH, the taker's proceeds are paid out of the maker's
     * escrow.
     *
     * @param orderId ID of the order to fill
     * @param baseTokenAmount Amount of base token to fill
     */
    function fillOrder(uint256 orderId, uint256 baseTokenAmount) external payable nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        require(order.isActive, "OTCTrading: order not active");

        // Check whitelist requirement for BOTH sides: a de-whitelisted maker's resting orders must
        // stop trading, not just be barred from creating new ones.
        if (requireWhitelist) {
            require(whitelist[msg.sender], "OTCTrading: not whitelisted");
            require(whitelist[order.maker], "OTCTrading: maker not whitelisted");
        }

        require(order.expiresAt == 0 || block.timestamp < order.expiresAt, "OTCTrading: order expired");
        require(order.maker != msg.sender, "OTCTrading: cannot fill own order");
        require(baseTokenAmount > 0, "OTCTrading: invalid fill amount");
        require(order.filledAmount + baseTokenAmount <= order.baseTokenAmount, "OTCTrading: exceeds order size");

        // Calculate counterparty token amount based on order price
        // Note: Division rounds down, which may cause minimal precision loss for very small amounts
        // For standard order sizes, this precision loss is negligible
        uint256 counterpartyTokenAmount = (baseTokenAmount * order.counterpartyTokenAmount) / order.baseTokenAmount;

        // Reject fills whose settlement rounds down to zero counterparty tokens.
        // Without this, a taker could repeatedly claim base tokens while paying nothing.
        require(counterpartyTokenAmount > 0, "OTCTrading: amount rounds to zero");

        // Fees use the order's snapshotted rates. The maker always bears the maker fee and the taker
        // the taker fee, in both directions.
        uint256 makerFee = (counterpartyTokenAmount * order.makerFeeBps) / 10000;
        uint256 takerFee = (counterpartyTokenAmount * order.takerFeeBps) / 10000;
        uint256 totalFee = makerFee + takerFee;

        bool isEth = _isETH(order.counterpartyToken);
        bool isSell = order.orderType == OrderType.SELL;
        address maker = order.maker;

        // The taker only ever SENDS ETH when buying base off a SELL order priced in ETH.
        uint256 takerOwes = counterpartyTokenAmount + takerFee;
        if (isEth && isSell) {
            require(msg.value >= takerOwes, "OTCTrading: insufficient ETH sent");
        } else {
            require(msg.value == 0, "OTCTrading: ETH not needed");
        }

        // ---- Effects: finish all state writes before any transfer or call ----
        order.filledAmount += baseTokenAmount;
        bool nowComplete = order.filledAmount >= order.baseTokenAmount;
        if (nowComplete) {
            order.isActive = false;
        }
        if (isEth && !isSell) {
            // Draw this fill's cost out of the maker's escrow: taker proceeds + both fees.
            ethEscrowed[orderId] -= counterpartyTokenAmount + makerFee;
            // On the closing fill, return any rounding dust so escrow accounting never strands ETH.
            if (nowComplete && ethEscrowed[orderId] > 0) {
                uint256 dust = ethEscrowed[orderId];
                ethEscrowed[orderId] = 0;
                emit EthEscrowRefunded(orderId, maker, dust);
                _creditETH(maker, dust);
            }
        }

        emit OrderFilled(orderId, msg.sender, baseTokenAmount, counterpartyTokenAmount, makerFee, takerFee);

        // ---- Interactions ----
        // ETH owed to resting parties (maker proceeds, fees) is CREDITED (pull-payment); only the
        // active taker (msg.sender) is paid inline.
        if (isSell) {
            // SELL order: maker sells base tokens, taker pays the counterparty side.
            IERC20(baseToken).safeTransferFrom(maker, msg.sender, baseTokenAmount);

            if (isEth) {
                _creditETH(maker, counterpartyTokenAmount - makerFee);
                _creditETH(feeRecipient, totalFee);
                if (msg.value > takerOwes) {
                    _sendETH(msg.sender, msg.value - takerOwes);
                }
            } else {
                IERC20 cpt = IERC20(order.counterpartyToken);
                cpt.safeTransferFrom(msg.sender, maker, counterpartyTokenAmount - makerFee);
                if (totalFee > 0) {
                    cpt.safeTransferFrom(msg.sender, feeRecipient, totalFee);
                }
            }
        } else {
            // BUY order: maker buys base tokens, taker sells them.
            IERC20(baseToken).safeTransferFrom(msg.sender, maker, baseTokenAmount);

            if (isEth) {
                // Credit fees first (state), then pay the taker inline last (CEI).
                _creditETH(feeRecipient, totalFee);
                _sendETH(msg.sender, counterpartyTokenAmount - takerFee);
            } else {
                IERC20 cpt = IERC20(order.counterpartyToken);
                cpt.safeTransferFrom(maker, msg.sender, counterpartyTokenAmount - takerFee);
                if (totalFee > 0) {
                    cpt.safeTransferFrom(maker, feeRecipient, totalFee);
                }
            }
        }
    }

    /**
     * @dev Cancel an order. Allowance-backed orders simply go inactive (no funds move); a BUY+ETH
     * order's unfilled escrow is refunded to the maker.
     * @param orderId ID of the order to cancel
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.maker == msg.sender, "OTCTrading: not order maker");
        require(order.isActive, "OTCTrading: order not active");

        order.isActive = false;

        emit OrderCancelled(orderId, msg.sender);

        _refundEscrow(orderId, msg.sender);
    }

    /**
     * @dev Batch cancel orders (only own orders)
     * @param orderIds Array of order IDs to cancel
     */
    function batchCancelOrders(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (order.maker == msg.sender && order.isActive) {
                order.isActive = false;
                emit OrderCancelled(orderIds[i], msg.sender);
                _refundEscrow(orderIds[i], msg.sender);
            }
        }
    }

    /**
     * @dev Cleanup expired orders. Permissionless: expiry is deterministic and ungameable, and the
     * caller gains nothing — a BUY+ETH order's escrow is refunded to its MAKER, never to the caller.
     * An underfunded (but unexpired) order is NOT cleanable by third parties, because underfunding is
     * transient; use {isOrderFundable} off-chain and let the maker cancel.
     * @param orderIds Array of order IDs to cleanup
     * @return cleanedCount Number of orders cleaned up
     */
    function cleanupExpiredOrders(uint256[] calldata orderIds) external nonReentrant returns (uint256 cleanedCount) {
        uint256 cleaned = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (order.isActive && order.expiresAt > 0 && block.timestamp >= order.expiresAt) {
                address maker = order.maker;
                order.isActive = false;
                cleaned++;
                _refundEscrow(orderIds[i], maker);
            }
        }
        emit OrdersCleanedUp(orderIds);
        return cleaned;
    }

    /**
     * @dev Withdraw your accrued ETH (maker proceeds, escrow refunds, or fees). Pull-payment
     * counterpart to the credits booked during fills and cancellations.
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "OTCTrading: nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        _sendETH(msg.sender, amount);
    }

    // ============ View Functions ============

    /**
     * @dev Get order details
     * @param orderId ID of the order
     * @return Order struct
     */
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @dev Get user's order IDs
     * @param user Address of the user
     * @return Array of order IDs
     */
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /**
     * @dev Get remaining amount in an order
     * @param orderId ID of the order
     * @return Remaining base token amount
     */
    function getRemainingAmount(uint256 orderId) external view returns (uint256) {
        Order memory order = orders[orderId];
        if (!order.isActive) {
            return 0;
        }
        if (order.expiresAt > 0 && block.timestamp >= order.expiresAt) {
            return 0;
        }
        return order.baseTokenAmount - order.filledAmount;
    }

    /**
     * @dev Check if order is expired
     * @param orderId ID of the order
     * @return True if order is expired
     */
    function isOrderExpired(uint256 orderId) external view returns (bool) {
        Order memory order = orders[orderId];
        if (!order.isActive || order.expiresAt == 0) {
            return false;
        }
        return block.timestamp >= order.expiresAt;
    }

    /**
     * @dev Check whether an order can currently be filled for its remaining amount. Because orders
     * are allowance-backed, a maker can move funds or revoke their approval at any time, so this is
     * a transient property: a false result does NOT deactivate the order. Frontends and relayers use
     * this to filter the book. A BUY+ETH order is escrowed and so is always fundable while live.
     * @param orderId ID of the order
     * @return True if the maker's side is currently covered
     */
    function isOrderFundable(uint256 orderId) public view returns (bool) {
        Order storage order = orders[orderId];
        if (!order.isActive) {
            return false;
        }
        if (order.expiresAt > 0 && block.timestamp >= order.expiresAt) {
            return false;
        }
        (address token, uint256 need) = _makerObligationRemaining(orderId);
        if (_isETH(token)) {
            return ethEscrowed[orderId] >= need;
        }
        return
            IERC20(token).allowance(order.maker, address(this)) >= need && IERC20(token).balanceOf(order.maker) >= need;
    }

    /**
     * @dev Get all active order IDs (gas intensive, use pagination in production)
     * @param offset Starting offset
     * @param limit Maximum number of orders to return
     * @return orderIds Array of active order IDs
     * @return total Total number of active orders
     */
    function getActiveOrders(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        require(limit > 0 && limit <= 100, "OTCTrading: invalid limit");

        // Count total active orders
        uint256 count = 0;
        for (uint256 i = 1; i < nextOrderId; i++) {
            Order memory order = orders[i];
            if (order.isActive && (order.expiresAt == 0 || block.timestamp < order.expiresAt)) {
                count++;
            }
        }

        uint256 resultCount = count > offset ? (count - offset > limit ? limit : count - offset) : 0;
        orderIds = new uint256[](resultCount);

        uint256 index = 0;
        uint256 found = 0;
        for (uint256 i = 1; i < nextOrderId && found < resultCount + offset; i++) {
            Order memory order = orders[i];
            if (order.isActive && (order.expiresAt == 0 || block.timestamp < order.expiresAt)) {
                if (found >= offset) {
                    orderIds[index] = i;
                    index++;
                }
                found++;
            }
        }

        return (orderIds, count);
    }

    /**
     * @dev Get orders by counterparty token
     * @param counterpartyToken Token address
     * @param offset Starting offset
     * @param limit Maximum number of orders to return
     * @return orderIds Array of order IDs
     */
    function getOrdersByToken(address counterpartyToken, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds)
    {
        require(limit > 0 && limit <= 100, "OTCTrading: invalid limit");

        uint256[] memory tempOrders = new uint256[](limit);
        uint256 count = 0;
        uint256 found = 0;

        for (uint256 i = 1; i < nextOrderId && count < limit; i++) {
            Order memory order = orders[i];
            if (order.counterpartyToken == counterpartyToken && order.isActive) {
                if (found >= offset) {
                    tempOrders[count] = i;
                    count++;
                }
                found++;
            }
        }

        orderIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = tempOrders[i];
        }

        return orderIds;
    }

    // ============ Internal Helpers ============

    /**
     * @dev Send native ETH to the ACTIVE caller, reverting loudly on failure. Used only for inline
     * payouts to msg.sender (taker proceeds / excess refund); resting parties are credited instead.
     */
    function _sendETH(address to, uint256 amount) private {
        if (amount == 0) {
            return;
        }
        (bool success,) = payable(to).call{value: amount}("");
        require(success, "OTCTrading: ETH transfer failed");
    }

    /**
     * @dev Book ETH as claimable for `to` (pull-payment). Never reverts on a hostile recipient, so a
     * maker/fee-recipient that cannot receive ETH can never block settlement or a cancel.
     */
    function _creditETH(address to, uint256 amount) private {
        if (amount == 0) {
            return;
        }
        pendingWithdrawals[to] += amount;
        emit EthCredited(to, amount);
    }

    /**
     * @dev Return a BUY+ETH order's unfilled escrow to its maker and zero the accounting. No-op for
     * every other order kind (nothing is ever escrowed for them). Callers must have already
     * deactivated the order; the balance is zeroed before crediting.
     * @param orderId ID of the order whose escrow is being released
     * @param maker The order's maker — the only valid recipient
     */
    function _refundEscrow(uint256 orderId, address maker) private {
        uint256 amount = ethEscrowed[orderId];
        if (amount == 0) {
            return;
        }
        ethEscrowed[orderId] = 0;
        emit EthEscrowRefunded(orderId, maker, amount);
        _creditETH(maker, amount);
    }

    /**
     * @dev What a maker must put up to fully back a fresh order: base tokens (SELL) or the
     * counterparty amount plus the maker fee (BUY). If `token` is ETH the obligation is met by
     * escrowing `amount` as msg.value; otherwise by an allowance.
     */
    function _makerObligation(
        OrderType orderType,
        address counterpartyToken,
        uint256 baseTokenAmount,
        uint256 counterpartyTokenAmount
    ) private view returns (address token, uint256 amount) {
        if (orderType == OrderType.SELL) {
            return (baseToken, baseTokenAmount);
        }
        uint256 makerFeeDeposit = (counterpartyTokenAmount * makerFeeBps) / 10000;
        return (counterpartyToken, counterpartyTokenAmount + makerFeeDeposit);
    }

    /**
     * @dev Same as {_makerObligation} but for an order's REMAINING unfilled part, using the order's
     * snapshotted fee rate. Used by {isOrderFundable}.
     */
    function _makerObligationRemaining(uint256 orderId) private view returns (address token, uint256 amount) {
        Order storage order = orders[orderId];
        uint256 remainingBaseAmount = order.baseTokenAmount - order.filledAmount;
        if (order.orderType == OrderType.SELL) {
            return (baseToken, remainingBaseAmount);
        }
        uint256 remainingCounterpartyAmount =
            (remainingBaseAmount * order.counterpartyTokenAmount) / order.baseTokenAmount;
        uint256 makerFeeRemaining = (remainingCounterpartyAmount * order.makerFeeBps) / 10000;
        return (order.counterpartyToken, remainingCounterpartyAmount + makerFeeRemaining);
    }
}
