// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IERC20.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure
 * Handles tokens that don't return a value or return false on failure
 */
library SafeERC20 {
    /**
     * @dev Transfer tokens safely
     * @param token The token to transfer
     * @param to The recipient address
     * @param value The amount to transfer
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    /**
     * @dev Transfer tokens from one address to another safely
     * @param token The token to transfer
     * @param from The sender address
     * @param to The recipient address
     * @param value The amount to transfer
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Approve spending safely (sets to 0 first to prevent race condition)
     * @param token The token to approve
     * @param spender The spender address
     * @param value The amount to approve
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // Set to 0 first to prevent race condition
        if (value > 0) {
            require(token.allowance(address(this), spender) == 0, "SafeERC20: approve non-zero to non-zero");
        }
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * @dev Increase allowance safely
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Decrease allowance safely
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
        uint256 newAllowance = oldAllowance - value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Call a token function and handle optional return value
     * Reverts if call fails or returns false
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token).call(data);

        require(success, "SafeERC20: low-level call failed");

        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
