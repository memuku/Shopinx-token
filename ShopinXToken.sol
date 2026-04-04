// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ShopinXToken is ERC20, ERC20Burnable, ERC20Pausable, Ownable, ERC20Permit {

    uint256 public constant MAX_SUPPLY = 500_000_000 * 10**18;

    // Basit kilit (tek seferlik acilis)
    mapping(address => uint256) public lockUntil;

    // Lineer vesting:
    // - cliffDays gun kilitli kalir
    // - Cliff bittikten sonra her stepDays gunluk dilimde stepPercent acilir
    // - Her dilim icinde acilis saniye bazli lineer akar (ani acilis olmaz)
    struct VestingInfo {
        uint256 totalAmount;  // toplam kilitli miktar
        uint256 startTime;    // vesting baslangic zamani
        uint256 cliffDays;    // ilk acilim icin bekleme (ornek: 30)
        uint256 stepPercent;  // her dilimde acilacak yuzde (ornek: 10)
        uint256 stepDays;     // dilim suresi gun cinsinden (ornek: 14)
        uint256 released;     // simdi kadar transfer edilen miktar
    }

    mapping(address => VestingInfo) public vesting;

    event TokensLocked(address indexed account, uint256 unlockTime);
    event VestingCreated(address indexed account, uint256 totalAmount, uint256 cliffDays, uint256 stepPercent, uint256 stepDays);
    event TokensReleased(address indexed account, uint256 amount);

    constructor(address recipient, address initialOwner)
        ERC20("ShopinX Token", "SPX")
        Ownable(initialOwner)
        ERC20Permit("ShopinX Token")
    {
        _mint(recipient, 200000000 * 10 ** decimals());
    }

    function pause() public onlyOwner { _pause(); }
    function unpause() public onlyOwner { _unpause(); }
    function mint(address to, uint256 amount) public onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply asiliyor");
        _mint(to, amount);
    }

    // Basit kilit (tek seferlik)
    function transferWithLock(address to, uint256 amount, uint256 unlockTime) public onlyOwner {
        require(unlockTime > block.timestamp, "Unlock time gecmiste olamaz");
        lockUntil[to] = unlockTime;
        _transfer(msg.sender, to, amount);
        emit TokensLocked(to, unlockTime);
    }

    function setLock(address account, uint256 unlockTime) public onlyOwner {
        require(unlockTime > block.timestamp, "Unlock time gecmiste olamaz");
        lockUntil[account] = unlockTime;
        emit TokensLocked(account, unlockTime);
    }

    function isLocked(address account) public view returns (bool) {
        return lockUntil[account] > block.timestamp;
    }

    // Lineer vesting ile transfer
    function transferWithVesting(
        address to,
        uint256 amount,
        uint256 cliffDays,
        uint256 stepPercent,
        uint256 stepDays
    ) public onlyOwner {
        require(stepPercent > 0 && stepPercent <= 100, "Gecersiz yuzde");
        require(stepDays > 0, "Gecersiz adim suresi");
        require(100 % stepPercent == 0, "100 stepPercent'e bolunebilmeli");

        require(vesting[to].totalAmount == 0, "Vesting zaten tanimli");
        vesting[to] = VestingInfo({
            totalAmount:  amount,
            startTime:    block.timestamp,
            cliffDays:    cliffDays,
            stepPercent:  stepPercent,
            stepDays:     stepDays,
            released:     0
        });

        _transfer(msg.sender, to, amount);
        emit VestingCreated(to, amount, cliffDays, stepPercent, stepDays);
    }

    // Simdi kadar acilan toplam miktar (lineer, saniye bazli)
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

    // Kac token su an transfer edilebilir
    function availableToTransfer(address account) public view returns (uint256) {
        VestingInfo memory v = vesting[account];
        if (v.totalAmount == 0) {
            if (block.timestamp >= lockUntil[account]) return balanceOf(account);
            return 0;
        }
        uint256 vested = vestedAmount(account);
        if (vested <= v.released) return 0;
        return vested - v.released;
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        if (from != address(0) && from != owner()) {
            VestingInfo storage v = vesting[from];

            if (v.totalAmount > 0) {
                uint256 vested = vestedAmount(from);
                require(vested > v.released, "Henuz acilan token yok");
                uint256 available = vested - v.released;
                require(value <= available, "Transfer miktari acilan miktari asiyor");
                v.released += value;
                emit TokensReleased(from, value);
            } else {
                require(
                    block.timestamp >= lockUntil[from],
                    "Token kilitli: henuz transfer edilemez"
                );
            }
        }
        super._update(from, to, value);
    }
}
