// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
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
 */
contract OTCTrading is Initializable, AccessControlUpgradeable, ReentrancyGuardTransient, PausableUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_RECIPIENT_ROLE = keccak256("FEE_RECIPIENT_ROLE");

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
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the OTC Trading contract
     * @param _baseToken Address of the base ERC20 token to trade
     * @param _defaultCounterpartyToken Default counterparty token (e.g., USDC)
     * @param _feeRecipient Address that receives trading fees
     * @param _admin Admin address
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
        _grantRole(FEE_RECIPIENT_ROLE, _feeRecipient);

        nextOrderId = 1;
    }

    // ============ Admin Functions ============

    /**
     * @dev Add an allowed counterparty token (can be ERC20 or address(0) for ETH)
     * @param token Address of the counterparty token (address(0) for ETH)
     */
    function addCounterpartyToken(address token) external onlyRole(ADMIN_ROLE) {
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

    // ============ Trading Functions ============

    /**
     * @dev Helper function to check if token is ETH
     */
    function _isETH(address token) private pure returns (bool) {
        return token == address(0);
    }

    /**
     * @dev Receive ETH
     */
    receive() external payable {
        // Allow contract to receive ETH
    }

    /**
     * @dev Create a new order (buy or sell)
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

        // Handle token transfers based on order type
        if (orderType == OrderType.SELL) {
            // SELL order: maker deposits base tokens
            IERC20(baseToken).safeTransferFrom(msg.sender, address(this), baseTokenAmount);
            require(msg.value == 0, "OTCTrading: ETH not needed for SELL order");
        } else {
            // BUY order: maker deposits the counterparty amount PLUS the maker fee.
            // The maker (buyer) bears the maker fee; the taker (seller) bears the
            // taker fee, deducted from proceeds at fill time. This mirrors the SELL
            // path so the fee incidence follows the maker/taker roles consistently.
            uint256 makerFeeDeposit = (counterpartyTokenAmount * makerFeeBps) / 10000;
            uint256 totalDeposit = counterpartyTokenAmount + makerFeeDeposit;
            if (_isETH(counterpartyToken)) {
                require(msg.value == totalDeposit, "OTCTrading: incorrect ETH amount");
            } else {
                require(msg.value == 0, "OTCTrading: ETH not needed for ERC20 token");
                IERC20(counterpartyToken).safeTransferFrom(msg.sender, address(this), totalDeposit);
            }
        }

        // Calculate expiration
        uint256 expirationTime = 0;
        if (defaultOrderExpiration > 0) {
            expirationTime = block.timestamp + defaultOrderExpiration;
        }

        // Create order
        orderId = nextOrderId++;
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
     * @param orderId ID of the order to fill
     * @param baseTokenAmount Amount of base token to fill
     */
    function fillOrder(uint256 orderId, uint256 baseTokenAmount) external payable nonReentrant whenNotPaused {
        // Check whitelist requirement
        if (requireWhitelist) {
            require(whitelist[msg.sender], "OTCTrading: not whitelisted");
        }

        Order storage order = orders[orderId];
        require(order.isActive, "OTCTrading: order not active");
        require(order.expiresAt == 0 || block.timestamp < order.expiresAt, "OTCTrading: order expired");
        require(order.maker != msg.sender, "OTCTrading: cannot fill own order");
        require(baseTokenAmount > 0, "OTCTrading: invalid fill amount");
        require(order.filledAmount + baseTokenAmount <= order.baseTokenAmount, "OTCTrading: exceeds order size");

        // Calculate counterparty token amount based on order price
        // Note: Division rounds down, which may cause minimal precision loss for very small amounts
        // For standard order sizes, this precision loss is negligible
        uint256 counterpartyTokenAmount = (baseTokenAmount * order.counterpartyTokenAmount) / order.baseTokenAmount;

        // Reject fills whose settlement rounds down to zero counterparty tokens.
        // Without this, a taker could repeatedly claim base tokens while paying
        // nothing (SELL) or drain the maker's deposit (BUY) via rounding dust.
        require(counterpartyTokenAmount > 0, "OTCTrading: amount rounds to zero");

        if (order.orderType == OrderType.SELL) {
            // SELL order: Maker is selling base tokens for counterparty tokens
            // Maker has base tokens in contract, wants counterparty tokens
            // Taker provides counterparty tokens, receives base tokens

            // Calculate fees on counterparty tokens using the order's snapshotted rates
            uint256 makerFee = (counterpartyTokenAmount * order.makerFeeBps) / 10000;
            uint256 takerFee = (counterpartyTokenAmount * order.takerFeeBps) / 10000;

            if (_isETH(order.counterpartyToken)) {
                // ETH counterparty: taker sends ETH
                require(msg.value >= counterpartyTokenAmount + takerFee, "OTCTrading: insufficient ETH sent");

                // Refund excess ETH if any
                if (msg.value > counterpartyTokenAmount + takerFee) {
                    (bool refundSuccess,) =
                        payable(msg.sender).call{value: msg.value - counterpartyTokenAmount - takerFee}("");
                    require(refundSuccess, "OTCTrading: ETH refund failed");
                }

                // Transfer ETH to maker (minus maker fee)
                (bool makerSuccess,) = payable(order.maker).call{value: counterpartyTokenAmount - makerFee}("");
                require(makerSuccess, "OTCTrading: ETH transfer to maker failed");

                // Transfer fees to fee recipient
                if (makerFee > 0) {
                    (bool makerFeeSuccess,) = payable(feeRecipient).call{value: makerFee}("");
                    require(makerFeeSuccess, "OTCTrading: ETH fee transfer failed");
                }
                if (takerFee > 0) {
                    (bool takerFeeSuccess,) = payable(feeRecipient).call{value: takerFee}("");
                    require(takerFeeSuccess, "OTCTrading: ETH fee transfer failed");
                }
            } else {
                // ERC20 counterparty
                require(msg.value == 0, "OTCTrading: ETH not needed for ERC20 token");

                // Transfer counterparty tokens from taker (including taker fee)
                IERC20(order.counterpartyToken)
                    .safeTransferFrom(msg.sender, address(this), counterpartyTokenAmount + takerFee);

                // Transfer counterparty tokens to maker (minus maker fee)
                IERC20(order.counterpartyToken).safeTransfer(order.maker, counterpartyTokenAmount - makerFee);

                // Transfer fees to fee recipient
                if (makerFee > 0) {
                    IERC20(order.counterpartyToken).safeTransfer(feeRecipient, makerFee);
                }
                if (takerFee > 0) {
                    IERC20(order.counterpartyToken).safeTransfer(feeRecipient, takerFee);
                }
            }

            // Transfer base tokens to taker
            IERC20(baseToken).safeTransfer(msg.sender, baseTokenAmount);

            emit OrderFilled(orderId, msg.sender, baseTokenAmount, counterpartyTokenAmount, makerFee, takerFee);
        } else {
            // BUY order: Maker is buying base tokens with counterparty tokens
            // Maker has counterparty tokens in contract, wants base tokens
            // Taker provides base tokens, receives counterparty tokens

            // Calculate fees on counterparty tokens using the order's snapshotted rates.
            // The maker fee was pre-funded by the maker at creation; the taker fee is
            // deducted from the taker's (seller's) proceeds here. Total disbursed is
            // `settlement + makerFee`, which is exactly what the maker deposited for
            // this fill, so the contract stays solvent.
            uint256 makerFee = (counterpartyTokenAmount * order.makerFeeBps) / 10000;
            uint256 takerFee = (counterpartyTokenAmount * order.takerFeeBps) / 10000;
            uint256 takerProceeds = counterpartyTokenAmount - takerFee;

            // Transfer base tokens from taker
            require(msg.value == 0, "OTCTrading: ETH not needed");
            IERC20(baseToken).safeTransferFrom(msg.sender, address(this), baseTokenAmount);

            // Transfer base tokens to maker
            IERC20(baseToken).safeTransfer(order.maker, baseTokenAmount);

            uint256 totalFee = makerFee + takerFee;

            if (_isETH(order.counterpartyToken)) {
                // ETH counterparty: transfer ETH to taker (minus taker fee)
                (bool takerSuccess,) = payable(msg.sender).call{value: takerProceeds}("");
                require(takerSuccess, "OTCTrading: ETH transfer to taker failed");

                // Transfer fees to fee recipient (from ETH held by contract)
                if (totalFee > 0) {
                    (bool feeSuccess,) = payable(feeRecipient).call{value: totalFee}("");
                    require(feeSuccess, "OTCTrading: ETH fee transfer failed");
                }
            } else {
                // ERC20 counterparty: transfer to taker (minus taker fee)
                IERC20(order.counterpartyToken).safeTransfer(msg.sender, takerProceeds);

                // Transfer fees to fee recipient (from counterparty tokens held by contract)
                if (totalFee > 0) {
                    IERC20(order.counterpartyToken).safeTransfer(feeRecipient, totalFee);
                }
            }

            emit OrderFilled(orderId, msg.sender, baseTokenAmount, counterpartyTokenAmount, makerFee, takerFee);
        }

        // Update order
        order.filledAmount += baseTokenAmount;
        if (order.filledAmount >= order.baseTokenAmount) {
            order.isActive = false;
        }
    }

    /**
     * @dev Refund the unfilled portion of a BUY order to its maker: the remaining
     * counterparty amount plus the still-unused maker-fee that was pre-funded at
     * creation. Using the same floor-division basis as fills guarantees the sum of
     * all fill outflows and this refund never exceeds the maker's original deposit.
     * @param order Storage reference to the BUY order
     * @param remainingBaseAmount Unfilled base amount
     */
    function _refundBuyOrder(Order storage order, uint256 remainingBaseAmount) private {
        uint256 remainingCounterpartyAmount =
            (remainingBaseAmount * order.counterpartyTokenAmount) / order.baseTokenAmount;
        uint256 makerFeeRefund = (remainingCounterpartyAmount * order.makerFeeBps) / 10000;
        uint256 refund = remainingCounterpartyAmount + makerFeeRefund;

        if (_isETH(order.counterpartyToken)) {
            (bool success,) = payable(order.maker).call{value: refund}("");
            require(success, "OTCTrading: ETH refund failed");
        } else {
            IERC20(order.counterpartyToken).safeTransfer(order.maker, refund);
        }
    }

    /**
     * @dev Cancel an order
     * @param orderId ID of the order to cancel
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.maker == msg.sender, "OTCTrading: not order maker");
        require(order.isActive, "OTCTrading: order not active");

        uint256 remainingBaseAmount = order.baseTokenAmount - order.filledAmount;
        require(remainingBaseAmount > 0, "OTCTrading: no remaining amount");

        if (order.orderType == OrderType.SELL) {
            // SELL order: return remaining base tokens to maker
            IERC20(baseToken).safeTransfer(order.maker, remainingBaseAmount);
        } else {
            // BUY order: return remaining counterparty tokens + unused maker fee
            _refundBuyOrder(order, remainingBaseAmount);
        }

        // Mark order as inactive
        order.isActive = false;

        emit OrderCancelled(orderId, msg.sender);
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

    /**
     * @dev Batch cancel orders (only own orders)
     * @param orderIds Array of order IDs to cancel
     */
    function batchCancelOrders(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (order.maker == msg.sender && order.isActive) {
                uint256 remainingBaseAmount = order.baseTokenAmount - order.filledAmount;
                if (remainingBaseAmount > 0) {
                    if (order.orderType == OrderType.SELL) {
                        IERC20(baseToken).safeTransfer(order.maker, remainingBaseAmount);
                    } else {
                        _refundBuyOrder(order, remainingBaseAmount);
                    }
                    order.isActive = false;
                    emit OrderCancelled(orderIds[i], msg.sender);
                }
            }
        }
    }

    /**
     * @dev Cleanup expired orders (admin only)
     * @param orderIds Array of order IDs to cleanup
     * @return cleanedCount Number of orders cleaned up
     */
    function cleanupExpiredOrders(uint256[] calldata orderIds)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        returns (uint256 cleanedCount)
    {
        uint256 cleaned = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (order.isActive && order.expiresAt > 0 && block.timestamp >= order.expiresAt) {
                uint256 remainingBaseAmount = order.baseTokenAmount - order.filledAmount;
                if (remainingBaseAmount > 0) {
                    if (order.orderType == OrderType.SELL) {
                        IERC20(baseToken).safeTransfer(order.maker, remainingBaseAmount);
                    } else {
                        _refundBuyOrder(order, remainingBaseAmount);
                    }
                }
                order.isActive = false;
                cleaned++;
            }
        }
        emit OrdersCleanedUp(orderIds);
        return cleaned;
    }

    /**
     * @dev Emergency withdrawal function (admin only)
     * @param token Token address (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw (0 = all balance)
     * @notice Only callable while the contract is paused, so an emergency
     * withdrawal is always preceded by a visible on-chain pause.
     */
    function emergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenPaused
    {
        require(to != address(0), "OTCTrading: invalid recipient");

        if (_isETH(token)) {
            uint256 balance = address(this).balance;
            uint256 withdrawAmount = amount == 0 ? balance : amount;
            require(withdrawAmount <= balance, "OTCTrading: insufficient balance");
            (bool success,) = payable(to).call{value: withdrawAmount}("");
            require(success, "OTCTrading: ETH transfer failed");
            emit EmergencyWithdrawal(token, to, withdrawAmount);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 withdrawAmount = amount == 0 ? balance : amount;
            require(withdrawAmount <= balance, "OTCTrading: insufficient balance");
            IERC20(token).safeTransfer(to, withdrawAmount);
            emit EmergencyWithdrawal(token, to, withdrawAmount);
        }
    }
}
