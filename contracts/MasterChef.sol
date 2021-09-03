// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./YerbamateToken.sol";

// MasterChef is the owner of Yerbamate
// To the deployer : remember to exclude the MasterChef from the Token Antiwhale
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of YERBAMATE
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accYerbamatePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accYerbamatePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. YERBAMATE to distribute per block.
        uint256 lastRewardBlock;  // Last block number that YERBAMATE distribution occurs.
        uint256 accYerbamatePerShare;   // Accumulated YERBAMATE per share, times 1e12. See below.
        uint256 depositFeeBP;      // Deposit fee in basis points
        uint256 harvestInterval;  // Harvest interval in seconds
        uint256 lpSupply;        // To determine more precisely the deposits and avoid the dilution of rewards
    }

    // The YERBAMATE TOKEN!
    YerbamateToken public yerbamate;
    // Dev address.
    address public devAddress;
    // YERBAMATE tokens created per block.
    uint256 public yerbamatePerBlock;
    // Deposit Fee address
    address public feeAddress;
    // Max tokens / block
    uint256 public constant MAX_EMISSION_RATE = 1 ether;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 1 days;

    uint public MaxSupply = 3000000e18; // 3M
    uint public endRewardBlock = 0;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when YERBAMATE mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;
        
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address previousFeeAddress, address newFeeAddress);
    event SetDevAddress(address previousDevAddress, address newDevAddress);
    event EmissionRateUpdated(uint256 previousAmount, uint256 newAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp); 
    event AddPool(uint256 indexed pid, uint256 allocPoint, address lpTokenAddress, uint256 depositFeeBP, uint256 harvestInterval, uint256 lastRewardBlock); 
    event SetPool(uint256 indexed pid, uint256 allocPoint, uint256 depositFeeBP, uint256 harvestInterval);

    constructor(
        YerbamateToken _yerbamate,
        address _devAddress,
        address _feeAddress,
        uint256 _yerbamatePerBlock,
        uint256 _startBlock
    ) public {
        yerbamate = _yerbamate;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
        yerbamatePerBlock = _yerbamatePerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner. With Harvest and Deposit Fee Capped.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint256 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 500, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval"); 

        // Test line to ensure the function will fail if the token doesn't exist
        _lpToken.balanceOf(address(this));
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accYerbamatePerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval: _harvestInterval,
            lpSupply: 0
        }));
        uint256 pid = poolInfo.length.sub(1);
        emit AddPool(pid, _allocPoint, address(_lpToken), _depositFeeBP, _harvestInterval, lastRewardBlock);
    }

    // Update the given pool's YERBAMATE allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint256 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 500, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        emit SetPool(_pid, _allocPoint, _depositFeeBP, _harvestInterval);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if(endRewardBlock > 0) return endRewardBlock.sub(_from);
        return _to.sub(_from);
    }

    // View function to see pending YERBAMATE on frontend.
    function pendingYerbamate(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accYerbamatePerShare = pool.accYerbamatePerShare;
        if (block.number > pool.lastRewardBlock && pool.lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 yerbamateReward = multiplier.mul(yerbamatePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accYerbamatePerShare = accYerbamatePerShare.add(yerbamateReward.mul(1e12).div(pool.lpSupply));
        }
        uint256 pending = user.amount.mul(accYerbamatePerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function _updatePool(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock || endRewardBlock > 0) {
            return;
        }
        if (pool.lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        if(yerbamate.totalSupply() >= MaxSupply) { // backup
        endRewardBlock = block.number;
        return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 yerbamateReward = multiplier.mul(yerbamatePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        if(yerbamate.totalSupply() + yerbamateReward > MaxSupply) {
           yerbamateReward = MaxSupply - yerbamate.totalSupply();
           endRewardBlock = block.number;
       }
        yerbamate.mint(devAddress, yerbamateReward.div(10));
        yerbamate.mint(address(this), yerbamateReward);
        pool.accYerbamatePerShare = pool.accYerbamatePerShare.add(yerbamateReward.mul(1e12).div(pool.lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Update reward variables of the given pool to be up-to-date (external version w/ non-reentrancy)
    function updatePool(uint256 _pid) external nonReentrant {
        _updatePool(_pid);
    }

    // Deposit LP tokens to MasterChef for YERBAMATE allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        _updatePool(_pid);
        _payOrLockupPendingYerbamate(_pid);
        if (_amount > 0) {
             // To handle correctly the transfer tax tokens w/ the pools
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);            
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accYerbamatePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        _updatePool(_pid);
        _payOrLockupPendingYerbamate(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accYerbamatePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        pool.lpSupply = pool.lpSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending YERBAMATE
    function _payOrLockupPendingYerbamate(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accYerbamatePerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // send rewards
                _safeYerbamateTransfer(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe yerbamate transfer function, just in case if rounding error causes pool to not have enough YERBAMATE.
    function _safeYerbamateTransfer(address _to, uint256 _amount) internal {
        uint256 yerbamateBal = yerbamate.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > yerbamateBal) {
            transferSuccess = yerbamate.transfer(_to, yerbamateBal);
        } else {
            transferSuccess = yerbamate.transfer(_to, _amount);
        }
        require(transferSuccess, "safeYerbamateTransfer: transfer failed");
    }

    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        address previousDevAddress = devAddress;
        devAddress = _devAddress;
        emit SetDevAddress(previousDevAddress, devAddress);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        address previousFeeAddress = feeAddress;
        feeAddress = _feeAddress;
        emit SetFeeAddress(previousFeeAddress, feeAddress);
    }

    function updateEmissionRate(uint256 _yerbamatePerBlock) public onlyOwner {
        require(_yerbamatePerBlock <= MAX_EMISSION_RATE, "YERBAMATE::updateEmissionRate: emission rate must not exceed the the maximum rate");
        massUpdatePools();
        uint256 previousYerbamatePerBlock = yerbamatePerBlock;
        yerbamatePerBlock = _yerbamatePerBlock;
        emit EmissionRateUpdated(previousYerbamatePerBlock, yerbamatePerBlock);
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
	    require(startBlock > block.number, "Farm already started");
        require(_startBlock > block.number, "Startblock has to be in the future");
        
        startBlock = _startBlock;
        //Set the last reward block to the new start block
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            poolInfo[pid].lastRewardBlock = startBlock;
        }
    }

}