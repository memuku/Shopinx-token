// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ShopinXToken is ERC20, ERC20Burnable, Ownable, ERC20Permit {

    mapping(address => uint256) public lockUntil;

    struct VestingInfo {
        uint256 totalAmount;
        uint256 startTime;
        uint256 cliffDays;
        uint256 stepPercent;
        uint256 stepDays;
    }

    mapping(address => VestingInfo) public vesting;

    event TokensLocked(address indexed account, uint256 unlockTime);
    event VestingCreated(address indexed account, uint256 totalAmount, uint256 cliffDays, uint256 stepPercent, uint256 stepDays);


    constructor(address recipient, address initialOwner)
        ERC20("ShopinX Token", "SPX")
        Ownable(initialOwner)
        ERC20Permit("ShopinX Token")
    {
        _mint(recipient, 300_000_000 * 10 ** decimals());
    }

    function transferWithLock(address to, uint256 amount, uint256 unlockTime) public onlyOwner {
        require(unlockTime > block.timestamp, "Unlock time must be in the future");
        require(unlockTime > lockUntil[to], "Cannot reduce existing lock");
        lockUntil[to] = unlockTime;
        _transfer(msg.sender, to, amount);
        emit TokensLocked(to, unlockTime);
    }

    function setLock(address account, uint256 unlockTime) public onlyOwner {
        require(unlockTime > block.timestamp, "Unlock time must be in the future");
        require(unlockTime > lockUntil[account], "Cannot reduce existing lock");
        lockUntil[account] = unlockTime;
        emit TokensLocked(account, unlockTime);
    }

    function isLocked(address account) public view returns (bool) {
        return lockUntil[account] > block.timestamp;
    }

    function transferWithVesting(
        address to,
        uint256 amount,
        uint256 cliffDays,
        uint256 stepPercent,
        uint256 stepDays
    ) public onlyOwner {
        require(stepPercent > 0 && stepPercent <= 100, "Invalid step percent");
        require(stepDays > 0, "Invalid step duration");
        require(100 % stepPercent == 0, "100 must be divisible by stepPercent");
        require(vesting[to].totalAmount == 0, "Vesting already defined");

        vesting[to] = VestingInfo({
            totalAmount:  amount,
            startTime:    block.timestamp,
            cliffDays:    cliffDays,
            stepPercent:  stepPercent,
            stepDays:     stepDays
        });

        _transfer(msg.sender, to, amount);
        emit VestingCreated(to, amount, cliffDays, stepPercent, stepDays);
    }

    function vestedAmount(address account) public view returns (uint256) {
        VestingInfo memory v = vesting[account];
        if (v.totalAmount == 0) return 0;

        uint256 elapsed      = block.timestamp - v.startTime;
        uint256 cliffSeconds = v.cliffDays * 1 days;

        if (elapsed < cliffSeconds) return 0;

        uint256 afterCliff  = elapsed - cliffSeconds;
        uint256 stepSeconds = v.stepDays * 1 days;
        uint256 totalSteps  = 100 / v.stepPercent;

        uint256 completedSteps = afterCliff / stepSeconds;
        if (completedSteps >= totalSteps) return v.totalAmount;

        uint256 vestedFromCompleted = (v.totalAmount * completedSteps * v.stepPercent) / 100;
        uint256 currentStepElapsed  = afterCliff % stepSeconds;
        uint256 currentStepAmount   = (v.totalAmount * v.stepPercent) / 100;
        uint256 vestedFromCurrent   = (currentStepAmount * currentStepElapsed) / stepSeconds;

        return vestedFromCompleted + vestedFromCurrent;
    }

    function availableToTransfer(address account) public view returns (uint256) {
        VestingInfo memory v = vesting[account];
        if (v.totalAmount == 0) {
            if (block.timestamp >= lockUntil[account]) return balanceOf(account);
            return 0;
        }
        uint256 vested = vestedAmount(account);
        uint256 locked = v.totalAmount - vested;
        uint256 balance = balanceOf(account);
        if (balance <= locked) return 0;
        return balance - locked;
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20)
    {
        if (from != address(0)) {
            require(
                block.timestamp >= lockUntil[from],
                "Token is locked: transfer not allowed yet"
            );
            VestingInfo storage v = vesting[from];
            if (v.totalAmount > 0) {
                uint256 locked = v.totalAmount - vestedAmount(from);
                require(balanceOf(from) >= value + locked, "Transfer amount exceeds unlocked balance");
            }
        }
        super._update(from, to, value);
    }
}
