// Socials
// Telegram:    https://t.me/polycowfinance
// Twitter:     https://twitter.com/polycow1
// Github:      https://github.com/polycow-finance
// Websie:      https://www.polycow.finance/

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import './utils/ReentrancyGuard.sol';
import './libs/SafeBEP20.sol';
import './Milk.sol';

// MasterCow is the master of Milk. He can make Milk and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Milk is sufficiently
// distributed and the community can show to govern itself.
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterCow is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Milk
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMilkPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMilkPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Milk to distribute per block.
        uint256 lastRewardBlock;  // Last block number that Milk distribution occurs.
        uint256 accMilkPerShare;   // Accumulated Milk per share, times 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The Milk Token!
    Milk public milk;
    address public devAddress;
    address public feeAddress;

    // Milk tokens created per block. 0.05 Milk / Block
    uint256 public constant BASE = 5;
    uint256 public constant TEN = 10;
    uint256 public constant HUNDRED = 100;
    uint256 public milkPerBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Milk mining starts.
    uint256 public startBlock;
    // Max deposit fee: 4%.
    uint16 public constant MAXIMUM_DEPOSIT_FEE_BP = 400;
    // Pool Exists Mapper
    mapping(IBEP20 => bool) public poolExistence;
    
    
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(!poolExistence[_lpToken], 'MasterCow: nonDuplicated: duplicated');
        _;
    }
    
    
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 YeldPerBlock);

    constructor(
        Milk _milk,
        address _devAddress,
        address _feeAddress
    ) public {
        milk = _milk;
        milkPerBlock = BASE.mul(TEN**milk.decimals()).div(HUNDRED);
        startBlock = block.number + 43200;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    
    

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool withUpdate) external onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_BP, 'MasterCow: add: invalid deposit fee basis points');
        if (withUpdate){
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accMilkPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's Milk allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP,  bool withUpdate) external onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_BP, 'MasterCow: set: invalid deposit fee basis points');
        if(withUpdate){
            massUpdatePools();
        }

        totalAllocPoint = (totalAllocPoint.add(_allocPoint)).sub(poolInfo[_pid].allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending Milk on frontend.
    function pendingMilk(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMilkPerShare = pool.accMilkPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 milkReward = multiplier.mul(milkPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accMilkPerShare = accMilkPerShare.add(milkReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMilkPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        for (uint256 pid = 0; pid < poolInfo.length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 milkReward = multiplier.mul(milkPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        milk.mint(devAddress, milkReward.div(10));
        milk.mint(address(this), milkReward);
        pool.accMilkPerShare = pool.accMilkPerShare.add(milkReward.mul(1e18).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterCow for Milk allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        updatePool(_pid);

        // harvest before deposit new amount
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMilkPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeMilkTransfer(_msgSender(), pending);
            }
        }

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accMilkPerShare).div(1e18);
        emit Deposit(_msgSender(), _pid, _amount);
    }

    // Withdraw LP tokens from MasterCow.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount >= _amount, 'MasterCow: withdraw: not good');
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMilkPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeMilkTransfer(_msgSender(), pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_msgSender(), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMilkPerShare).div(1e18);
        emit Withdraw(_msgSender(), _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(_msgSender(), amount);
        emit EmergencyWithdraw(_msgSender(), _pid, amount);
    }

    // Safe Milk transfer function, just in case if rounding error causes pool to not have enough Milks.
    function safeMilkTransfer(address _to, uint256 _amount) internal {
        uint256 milkBalance = milk.balanceOf(address(this));
        bool transferSuccess = _amount > milkBalance ? milk.transfer(_to, milkBalance) : milk.transfer(_to, _amount);
        require(transferSuccess, 'MasterCow: safeMilkTransfer: Transfer failed');
    }

    // Update dev address by the previous dev.
    function setDevAddress(address devAddress_) public {
        require(_msgSender() == devAddress, 'MasterCow: setDevAddress: Only dev can set');
        devAddress = devAddress_;
        emit SetDevAddress(_msgSender(), devAddress_);
    }

    function setFeeAddress(address feeAddress_) public {
        require(_msgSender() == feeAddress, 'MasterCow: setFeeAddress: Only feeAddress can set');
        feeAddress = feeAddress_;
        emit SetFeeAddress(_msgSender(), feeAddress_);
    }

    function updateEmissionRate(uint256 _milkPerBlock) external onlyOwner {
        massUpdatePools();
        milkPerBlock = _milkPerBlock;
        emit UpdateEmissionRate(_msgSender(), _milkPerBlock);
    }

    function updateStartBlock(uint256 startBlock_) public onlyOwner {
	    require(startBlock_ > block.number, 'MasterCow: updateStartBlock: No timetravel allowed!');
        startBlock = startBlock_;
    }


 
}