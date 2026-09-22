// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OTCTrading} from "../../src/OTCTrading.sol";
import {IEligibilityRegistry} from "../../src/compliance/IEligibilityRegistry.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A party that refuses ETH: proves pull-payments keep a hostile maker or fee recipient from
/// blocking settlement, and that only the inline path to the caller reverts.
contract EthRejecter {
    function createOrder(OTCTrading otc, uint256 offeringId, OTCTrading.OrderType t, uint256 base, uint256 cpt)
        external
        payable
        returns (uint256)
    {
        return otc.createOrder{value: msg.value}(offeringId, t, address(0), base, cpt);
    }

    function fillOrder(OTCTrading otc, uint256 orderId, uint256 base) external payable {
        otc.fillOrder{value: msg.value}(orderId, base);
    }

    function withdraw(OTCTrading otc) external {
        otc.withdraw();
    }
}

/// @dev A gate that reverts on every question, to prove the compliance check fails CLOSED.
contract RevertingRegistry is IEligibilityRegistry {
    bool public armed;

    function arm() external {
        armed = true;
    }

    function isEligible(address) external view override returns (bool) {
        // Answers during `createOffering`'s probe, then refuses to answer at all.
        if (armed) revert("registry down");
        return true;
    }
}

/// @dev A gate that answers but is not a registry at all — returns nothing, so the call decodes
/// to garbage and the `try` block's return decoding fails.
contract NotARegistry {
    fallback() external {}
}

// --- ERC-3643 stand-ins, enough for ERC3643EligibilityAdapter ---

contract MockIdentityRegistry {
    mapping(address => bool) public verified;

    function setVerified(address account, bool v) external {
        verified[account] = v;
    }

    function isVerified(address account) external view returns (bool) {
        return verified[account];
    }
}

contract MockERC3643Token is ERC20 {
    address public identityRegistry;

    constructor(address registry) ERC20("Security", "SEC") {
        identityRegistry = registry;
    }

    function setIdentityRegistry(address registry) external {
        identityRegistry = registry;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal ERC-2771 forwarder: appends the original sender to the calldata.
contract MockForwarder {
    function relay(address target, bytes calldata data, address sender) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(abi.encodePacked(data, sender));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
