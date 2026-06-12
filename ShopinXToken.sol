// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ShopinXToken is ERC20, ERC20Burnable, Ownable2Step, ERC20Permit {

    // Named constants
    uint256 public constant INITIAL_SUPPLY  = 1_000_000_000e18;
    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;
    uint256 public constant MAX_CLIFF_DAYS  = 36500;
    uint256 public constant MAX_STEP_DAYS   = 36500;
    uint256 public constant PERCENT_BASE    = 100;

    // Full-address freeze (setLock) — blocks ALL outgoing transfers
    mapping(address => uint256) public freezeUntil;

    // Amount-based lock (transferWithLock) — blocks only the locked tranche
    mapping(address => uint256) public lockedAmount;
    mapping(address => uint256) public lockedUntil;

    // Zero totalAmount is the sentinel for "no schedule set"
    struct VestingInfo {
        uint128 totalAmount;
        uint32  startTime;
        uint32  cliffDays;
        uint32  stepPercent;
        uint32  stepDays;
    }

    mapping(address => VestingInfo) public vesting;

    event TokensFreezed(address indexed account, uint256 until);
    event TokensLocked(address indexed account, uint256 amount, uint256 unlockTime);
    event VestingCreated(
        address indexed account,
        uint256 totalAmount,
        uint256 cliffDays,
        uint256 stepPercent,
        uint256 stepDays
    );

    // recipient: initial 1B token holder (treasury / deployer wallet)
    // initialOwner: administrative key (multisig recommended)
    constructor(address recipient, address initialOwner)
        ERC20("ShopinX Token", "SPX")
        Ownable(initialOwner)
        ERC20Permit("ShopinX Token")
    {
        _mint(recipient, INITIAL_SUPPLY);
    }

    // Prevent accidental permanent loss of all administrative functions
    function renounceOwnership() public pure override(Ownable) {
        revert("Ownership cannot be renounced");
    }

    // ─── Lock primitives ────────────────────────────────────────────────────

    // Freeze entire balance of account until unlockTime (max 4 years)
    function setLock(address account, uint256 unlockTime) external onlyOwner {
        require(account != address(0), "Invalid address");
        require(unlockTime > block.timestamp, "Unlock time must be in the future");
        require(unlockTime <= block.timestamp + MAX_LOCK_DURATION, "Lock duration too long");
        freezeUntil[account] = unlockTime;
        emit TokensFreezed(account, unlockTime);
    }

    // Remove full-address freeze (owner can correct mistakes)
    function removeLock(address account) external onlyOwner {
        freezeUntil[account] = 0;
        emit TokensFreezed(account, 0);
    }

    // Transfer + lock only the transferred amount (not the recipient's pre-existing balance)
    function transferWithLock(
        address to,
        uint256 amount,
        uint256 unlockTime
    ) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Amount must be positive");
        require(unlockTime > block.timestamp, "Unlock time must be in the future");
        require(unlockTime <= block.timestamp + MAX_LOCK_DURATION, "Lock duration too long");
        lockedAmount[to] = amount;
        lockedUntil[to]  = unlockTime;
        _transfer(msg.sender, to, amount);
        emit TokensLocked(to, amount, unlockTime);
    }

    function isLocked(address account) external view returns (bool) {
        return freezeUntil[account] > block.timestamp ||
               (lockedUntil[account] > block.timestamp && lockedAmount[account] > 0);
    }

    // ─── Vesting ────────────────────────────────────────────────────────────

    function transferWithVesting(
        address to,
        uint256 amount,
        uint256 cliffDays,
        uint256 stepPercent,
        uint256 stepDays
    ) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Amount must be positive");
        require(stepPercent > 0 && stepPercent <= PERCENT_BASE, "Invalid step percent");
        require(stepDays > 0 && stepDays <= MAX_STEP_DAYS, "Invalid step duration");
        require(cliffDays <= MAX_CLIFF_DAYS, "Cliff too long");
        require(PERCENT_BASE % stepPercent == 0, "100 must be divisible by stepPercent");
        require(vesting[to].totalAmount == 0, "Vesting already defined");

        vesting[to] = VestingInfo({
            totalAmount: uint128(amount),
            startTime:   uint32(block.timestamp),
            cliffDays:   uint32(cliffDays),
            stepPercent: uint32(stepPercent),
            stepDays:    uint32(stepDays)
        });

        _transfer(msg.sender, to, amount);
        emit VestingCreated(to, amount, cliffDays, stepPercent, stepDays);
    }

    function vestedAmount(address account) public view returns (uint256) {
        VestingInfo memory v = vesting[account];
        if (v.totalAmount == 0) return 0;

        uint256 elapsed      = block.timestamp - uint256(v.startTime);
        uint256 cliffSeconds = uint256(v.cliffDays) * 1 days;
        if (elapsed < cliffSeconds) return 0;

        uint256 afterCliff  = elapsed - cliffSeconds;
        uint256 stepSeconds = uint256(v.stepDays) * 1 days;
        uint256 totalSteps  = PERCENT_BASE / uint256(v.stepPercent);

        uint256 completedSteps = afterCliff / stepSeconds;
        if (completedSteps >= totalSteps) return uint256(v.totalAmount);

        // Multiply before divide to minimise precision loss
        uint256 vestedFromCompleted = (uint256(v.totalAmount) * completedSteps * uint256(v.stepPercent)) / PERCENT_BASE;
        // Deterministic time-interpolation within the current step (not randomness)
        uint256 currentStepElapsed  = afterCliff % stepSeconds;
        uint256 vestedFromCurrent   = (uint256(v.totalAmount) * uint256(v.stepPercent) * currentStepElapsed) / (PERCENT_BASE * stepSeconds);

        return vestedFromCompleted + vestedFromCurrent;
    }

    // Returns how many tokens account can transfer right now
    function availableToTransfer(address account) external view returns (uint256) {
        // Full-address freeze takes priority
        if (block.timestamp < freezeUntil[account]) return 0;

        uint256 balance = balanceOf(account);

        uint256 amountLocked = 0;
        if (lockedUntil[account] > block.timestamp) {
            amountLocked = lockedAmount[account];
        }

        VestingInfo memory v = vesting[account];
        uint256 vestingLocked = 0;
        if (v.totalAmount > 0) {
            vestingLocked = uint256(v.totalAmount) - vestedAmount(account);
        }

        uint256 totalLocked = amountLocked + vestingLocked;
        if (balance <= totalLocked) return 0;
        return balance - totalLocked;
    }

    // ─── Transfer gate ──────────────────────────────────────────────────────

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20) {
        if (from != address(0)) {
            bool isBurn = (to == address(0));

            // Full-address freeze — burns are allowed so holders can always destroy unlocked tokens
            if (!isBurn) {
                require(
                    block.timestamp >= freezeUntil[from],
                    "Token is frozen: transfer not allowed yet"
                );
            }

            // Amount-based lock (only blocks the locked tranche)
            uint256 amountLocked = 0;
            if (lockedUntil[from] > block.timestamp) {
                amountLocked = lockedAmount[from];
            }

            // Vesting lien (fungible reserve against total balance)
            VestingInfo storage v = vesting[from];
            uint256 vestingLocked = 0;
            if (v.totalAmount > 0) {
                vestingLocked = uint256(v.totalAmount) - vestedAmount(from);
            }

            uint256 totalLocked = amountLocked + vestingLocked;
            if (totalLocked > 0) {
                require(
                    balanceOf(from) >= value + totalLocked,
                    "Transfer amount exceeds unlocked balance"
                );
            }
        }
        super._update(from, to, value);
    }
}
