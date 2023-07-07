// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {ERC20RebaseDistributor} from "@src/tokens/ERC20RebaseDistributor.sol";

/** 
@title  CREDIT ERC20 Token
@author eswak
@notice This is the debt token of the Ethereum Credit Guild.
*/
contract CreditToken is CoreRef, ERC20Burnable, ERC20MultiVotes, ERC20RebaseDistributor {
    constructor(
        address _core
    )
        CoreRef(_core)
        ERC20("Ethereum Credit Guild - CREDIT", "CREDIT")
        ERC20Permit("Ethereum Credit Guild - CREDIT")
    {}

    /// @notice mint new tokens to the target address
    function mint(
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.CREDIT_MINTER) {
        _mint(to, amount);
    }

    /*///////////////////////////////////////////////////////////////
                        Inheritance reconciliation
    //////////////////////////////////////////////////////////////*/

    function _mint(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20RebaseDistributor) {
        ERC20RebaseDistributor._mint(account, amount);
    }

    function _burn(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20MultiVotes, ERC20RebaseDistributor) {
        _decrementVotesUntilFree(account, amount); // from ERC20MultiVotes
        ERC20RebaseDistributor._burn(account, amount);
    }

    function balanceOf(
        address account
    ) public view override(ERC20, ERC20RebaseDistributor) returns (uint256) {
        return ERC20RebaseDistributor.balanceOf(account);
    }

    function totalSupply() public view override(ERC20, ERC20RebaseDistributor) returns (uint256) {
        return ERC20RebaseDistributor.totalSupply();
    }

    function transfer(
        address to,
        uint256 amount
    ) public override(ERC20, ERC20MultiVotes, ERC20RebaseDistributor) returns (bool) {
        _decrementVotesUntilFree(msg.sender, amount); // from ERC20MultiVotes
        return ERC20RebaseDistributor.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20, ERC20MultiVotes, ERC20RebaseDistributor) returns (bool) {
        _decrementVotesUntilFree(from, amount); // from ERC20MultiVotes
        return ERC20RebaseDistributor.transferFrom(from, to, amount);
    }
}
