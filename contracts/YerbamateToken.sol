// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts/access/Ownable.sol';

contract YerbamateToken is ERC20('Yerba Mate', 'YERBAMATE'), Ownable {

    /// @dev Capped supply to 3 millions in the Constructor()
    uint256 private immutable _cap; 

    // Addresses
    /// @dev Dev address
    address public constant DEV_ADDRESS = 0x0e5a10379E2c26878D4BfF3b65c356DC41e34652;
    /// @dev Fee address
    address public constant FEE_ADDRESS = 0x14580b635aa93e56BD131e17d70A1c76a8B0a12a;

    // Anti-Whale & Anti-Bot
    /// @dev Addresses excluded from MaxTransfer
    mapping(address => bool) private _excludedFromMaxTransfer;
    /// @dev Max transfer amount rate in basis points: 2%
    uint16 private constant maxTransferAmountRate = 200;
    /// @dev Addresses excluded from MaxHolding
    mapping(address => bool) private _excludedFromMaxHolding;
    /// @dev Max holding rate amount in basis point: 2%
    uint16 private constant maxHoldingRate = 200;
    /// @dev antibot enable/disable
    bool public antibot_active;

    /// @dev OnlyOperator
    address private _operator;

    /// @dev Events
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);

    constructor(uint256 cap_) public {
        require(cap_ > 0, "ERC20Capped: cap is 0");
        _cap = cap_;

        _operator = _msgSender();
       
        _excludedFromMaxTransfer[address(this)] = true;
        _excludedFromMaxTransfer[DEV_ADDRESS] = true;

        _excludedFromMaxHolding[address(this)] = true;
        _excludedFromMaxHolding[address(0)] = true;
        _excludedFromMaxHolding[DEV_ADDRESS] = true;

        antibot_active = true;
    } 
    modifier onlyOperator() {
        require(_operator == msg.sender, "YERBAMATE: Caller is not the operator");
        _;
    }  
    
    modifier maxTransfer(address sender, address recipient, uint256 amount) {
        if ( _excludedFromMaxTransfer[sender] == false && _excludedFromMaxTransfer[recipient] == false) {
            require(amount <= maxTransferAmount(), "YERBAMATE::AntiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        _;
    }

    modifier maxHolding(address sender, address recipient, uint256 amount) {
        if ( _excludedFromMaxHolding[sender] == false && _excludedFromMaxHolding[recipient] == false) {
                require(balanceOf(recipient).add(amount) < maxHoldingAmount(),"YERBAMATE::AntiWhale: You reach the max wallet limit");
            }
        _;
    }

    /// @dev Returns the address of the current operator
    function operator() public view returns (address) {
        return _operator;
    }

    /// @dev Returns capped supply
    function cap() public view virtual returns (uint256) {
        return _cap;
    }
    /// @dev Returns the max transfer amount
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }
    /// @dev Returns the max holding amount
    function maxHoldingAmount() public view returns (uint256) {
        return totalSupply().mul(maxHoldingRate).div(10000);
    }
    /// @dev Returns the address is excluded from MaxTransfer
    function isExcludedFromMaxTransfer(address _account) public view returns (bool) {
        return _excludedFromMaxTransfer[_account];
    }

        /// @dev Returns the address is excluded from MaxHolding
    function isExcludedFromMaxHolding(address _account) public view returns (bool) {
        return _excludedFromMaxHolding[_account];
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override maxTransfer(sender, recipient, amount) maxHolding(sender, recipient, amount) {
        if (recipient == address(0) || sender == DEV_ADDRESS || recipient == DEV_ADDRESS) {
            super._transfer(sender, recipient, amount);
        } 
        else {
            if (antibot_active) {
                super._burn(sender, amount);
            } 
            else {
                super._transfer(sender, recipient, amount);

            }
        } 
    }

    /// @dev Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef)
    function mint(address _to, uint256 _amount) public onlyOwner {
        require(totalSupply().add(_amount) <= cap(), "YERBAMATE: Cap exceeded"); 
        _mint(_to, _amount);
    }

    /// @dev Transfers operator of the contract to a new account (`newOperator`)
    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0), "YERBAMATE:: New operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

        /// @dev Exclude from the MaxTransfer
    function setExcludedFromMaxTransfer(address _account, bool _excluded) public onlyOperator {
        _excludedFromMaxTransfer[_account] = _excluded;
    }

    /// @dev Exclude from the MaxHolding
    function setExcludedFromMaxHolding(address _account, bool _excluded) public onlyOperator {
        _excludedFromMaxHolding[_account] = _excluded;
    }

    /// @dev Disable Anti-Bot. Only runs once
    function Antibot() public onlyOwner {
        require(antibot_active = true);
        antibot_active = false;
    }

}