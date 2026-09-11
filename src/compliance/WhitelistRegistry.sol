// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IEligibilityRegistry} from "./IEligibilityRegistry.sol";

/**
 * @title WhitelistRegistry
 * @notice The "manual whitelist" compliance option: an operator-kept list of addresses allowed to
 * trade, deployed once and shared by every offering that names it.
 *
 * @dev This lives OUTSIDE the trading contract on purpose. v1 kept the list in contract storage,
 * which meant one whitelist for one deployment; with several offerings under one contract that is
 * exactly the wrong shape — a fund's investors and a token's retail holders are different lists,
 * and they must not share a switch. Keeping each list in its own contract lets offerings share one
 * where they should, keeps the trading contract's audit surface flat, and lets an offering graduate
 * to a stronger gate — an ERC-3643 adapter, say — without touching this one.
 */
contract WhitelistRegistry is IEligibilityRegistry, Ownable2Step {
    /// @dev Mirrors the trading contract's batch ceiling.
    uint256 public constant MAX_BATCH_SIZE = 200;

    mapping(address => bool) private _whitelisted;

    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IEligibilityRegistry
    function isEligible(address account) external view override returns (bool) {
        return _whitelisted[account];
    }

    function isWhitelisted(address account) external view returns (bool) {
        return _whitelisted[account];
    }

    function add(address account) external onlyOwner {
        _add(account);
    }

    function remove(address account) external onlyOwner {
        _remove(account);
    }

    function addBatch(address[] calldata accounts) external onlyOwner {
        require(accounts.length > 0 && accounts.length <= MAX_BATCH_SIZE, "WhitelistRegistry: invalid batch size");
        for (uint256 i = 0; i < accounts.length; i++) {
            _add(accounts[i]);
        }
    }

    function removeBatch(address[] calldata accounts) external onlyOwner {
        require(accounts.length > 0 && accounts.length <= MAX_BATCH_SIZE, "WhitelistRegistry: invalid batch size");
        for (uint256 i = 0; i < accounts.length; i++) {
            _remove(accounts[i]);
        }
    }

    function _add(address account) private {
        require(account != address(0), "WhitelistRegistry: invalid account");
        if (!_whitelisted[account]) {
            _whitelisted[account] = true;
            emit WhitelistAdded(account);
        }
    }

    function _remove(address account) private {
        if (_whitelisted[account]) {
            _whitelisted[account] = false;
            emit WhitelistRemoved(account);
        }
    }
}
