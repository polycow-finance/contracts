// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import './libs/SafeBEP20.sol';
import './utils/Ownable.sol';
import './utils/VRFConsumerBase.sol';

contract MilkyGame is Ownable, VRFConsumerBase{
    using SafeMathChainlink for uint256;
    using SafeBEP20 for IBEP20;

    
    // STRUCTS

    uint256 public constant MAX_DEP_FEE = 400;
    uint256 public constant MAX_POINTS_PER_POOL = 20;
    uint256 public constant MIN_POINTS_PER_POOL = 5;
    uint256 public constant MIN_POOL_NUMBER = 4;
    uint256 public constant MAX_DURATION = 48 hours;

    struct GameInfo{
        uint256 poolNumber;
        uint256 pointsPerPool;
        uint256 depositFee;
        uint256 endTimestamp;
        IBEP20 stakingRewardToken;
        address gameDeployer;
    }

    struct GameState{
        bool emergency;
        bool chosenNumberInit;
        bool chosenNumberAsig;
        bool finalNumberAsig;
        bool anyClaim;
        bool gameInit;
        bool gameFinished;
        bool amountToShareAsig;
        uint256 amountToShare;
    }

    struct PoolInfo{
        uint256 amountDeposited;
        uint256 amountAccumulated;
    }




    // ESSENTIALS
    bytes32 internal keyHash;
    uint256 internal fee;

    // PUBLICS
    GameState public gameState;
    GameInfo public gameInfo;
    mapping(address=>uint256[]) public userInfo;
    mapping(address=>bool) public claimed;
    mapping(address=>uint256) public deposited;
    PoolInfo[] public poolInfo;
    
    // PRIVATES
    uint256 public chosenNumber = 10 ether; // initial number.. must change!!
    uint256 public finalNumber = 10 ether; // initial number.. must change!!

    // EVENTS

    // MODIFIERS

    modifier gameInitiated{
        require(gameState.gameInit,'error');
        _;
    }

    modifier gameFinished{
        require(gameState.gameInit && gameState.gameFinished, 'error');
        _;
    }

    modifier winnerChosen {
        require(gameState.chosenNumberInit && gameState.chosenNumberAsig && gameState.finalNumberAsig, 'error');
        _;
    }

    modifier notEmergency {
        require (!gameState.emergency, 'error');
        _;
    }

    constructor()
        VRFConsumerBase(
            0x3d2341ADb2D31f1c5530cDC622016af293177AE0, // VRF Coordinator MainNet!!!
            0xb0897686c545045aFc77CF20eC7A532E3120E0F1  // LINK Token MainNet!!!!
        ) public
    {
        keyHash = 0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da; // MainNet!!!
        fee = 0.0001  * 10 ** 18; // 0.0001 LINK
        gameInfo.endTimestamp = uint256(-1);
    }

    function getRandomNumber() internal returns (bytes32 requestId) {
        require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK - fill contract with faucet");
        return requestRandomness(keyHash, fee);
    }

    /**
    * Callback function used by VRF Coordinator
    */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        gameState.chosenNumberAsig = true;
        chosenNumber = randomness.mod((gameInfo.poolNumber.mul(gameInfo.pointsPerPool)).add(1));
    }

    function initializeGame(uint256 poolNumber_, uint256 pointsPerPool_, uint256 depositFee_, uint256 duration_ ,IBEP20 stakingRewardToken_, uint256 initialFunds_ )public onlyOwner{
        require(!gameState.gameInit,'error');
        require(poolNumber_>= MIN_POOL_NUMBER,'error');
        require(((pointsPerPool_>= MIN_POINTS_PER_POOL) && (pointsPerPool_<= MAX_POINTS_PER_POOL)) , 'error');
        require(depositFee_<= MAX_DEP_FEE, 'error');
        require(duration_<= MAX_DURATION, 'error');

        gameState.gameInit = true;
        //Initialize gameInfo
        initializeGameInfo(poolNumber_,pointsPerPool_,depositFee_,duration_,stakingRewardToken_);
        //Initialize poolInfo array to right size
        for(uint i = 0; i<gameInfo.poolNumber; ++i){
            poolInfo.push(PoolInfo(0,0));
        }
        // poolInfo = new PoolInfo[] (gameInfo.poolNumber);
        //Transfer Link amount to contract
        LINK.transferFrom(_msgSender(), address(this), fee);
        //Transfer funds and spread them into the pools
        spreadFunds(initialFunds_);
    }

    function increasePrice(uint256 funds_) public gameInitiated notEmergency {
        require(!gameState.gameFinished, 'error');
        spreadFunds(funds_);
    }

    function deposit(uint256 amount, uint256 pool) public gameInitiated notEmergency{
        require(!gameState.gameFinished, 'error');
        require(pool<gameInfo.poolNumber, 'error');
        address sender = _msgSender();
        if (amount!=0){
            uint256 depositedAmount = gameInfo.stakingRewardToken.balanceOf(address(this));
            gameInfo.stakingRewardToken.safeTransferFrom(sender, address(this), amount);
            uint256 efectiveDepAmount = gameInfo.stakingRewardToken.balanceOf(address(this)).sub(depositedAmount);
            
            // TODO CALCULATE IF DEPOSIT FEE ACTIVE AND TRANSFER OUT THAT FEE

            if (userInfo[sender].length == 0){ // first time user deposits anypool
                userInfo[sender] = new uint256[] (gameInfo.poolNumber);
            }
            userInfo[sender][pool] = userInfo[sender][pool].add(efectiveDepAmount);
            deposited[sender] = deposited[sender].add(efectiveDepAmount);
            poolInfo[pool].amountAccumulated = poolInfo[pool].amountAccumulated.add(efectiveDepAmount);
            poolInfo[pool].amountDeposited = poolInfo[pool].amountDeposited.add(efectiveDepAmount);
        }
        gameState.gameFinished = checkFinishGame();
    }

    function isFinished() public view returns(bool){
        return checkFinishGame();
    }

    function getUserInfo(address user) public view returns(uint256[] memory){
        return userInfo[user];
    }

    
    function emergencyGetChosenNumber() public gameFinished notEmergency onlyOwner{
        gameState.chosenNumberInit = true;
        getRandomNumber();
    }
   
    function getChosenNumber() public gameFinished notEmergency {
        require(!gameState.chosenNumberInit,'error');
        gameState.chosenNumberInit = true;
        getRandomNumber();
    }

    function getFinalNumber() public gameFinished notEmergency{
        require(gameState.chosenNumberAsig,'error');
        require(!gameState.finalNumberAsig, 'error');
        gameState.finalNumberAsig = true;
        finalNumber = choseFinalNumber();
    }

    function claimPrice() public gameFinished notEmergency winnerChosen{
        require(!claimed[_msgSender()],'error');
        rollOverAndAmount();
        if (finalNumber<gameInfo.poolNumber){
            uint256 myShare = userInfo[_msgSender()][finalNumber];
            uint256 poolDep = poolInfo[finalNumber].amountDeposited;
            if (poolDep != 0){
                uint256 myWinnings = (gameState.amountToShare.mul(myShare)).div(poolDep);
                if (myWinnings>0) {
                    safePriceTransfer(myWinnings);
                }
            }
        }
        gameState.anyClaim = true;
        claimed[_msgSender()] = true;
    }

    function callEmergency() public onlyOwner notEmergency{
        require (!gameState.anyClaim, 'error');
        gameState.emergency = true;
    }

    function emergencyWithdraw() public {
        require(gameState.emergency, 'error');
        safePriceTransfer(deposited[_msgSender()]);
    }

    function safePriceTransfer(uint256 amount) internal {
        uint256 balance = gameInfo.stakingRewardToken.balanceOf(address(this));
        if(amount>balance){
            gameInfo.stakingRewardToken.safeTransfer(_msgSender(), balance);
        }else{
            gameInfo.stakingRewardToken.safeTransfer(_msgSender(), amount);
        }
    }

    function rollOverAndAmount() internal {
        if(gameState.amountToShareAsig) return;
        gameState.amountToShareAsig = true;
        if(finalNumber<gameInfo.poolNumber){
            gameInfo.stakingRewardToken.safeTransfer(gameInfo.gameDeployer, poolInfo[finalNumber].amountAccumulated);
        }else{
            gameInfo.stakingRewardToken.safeTransfer(gameInfo.gameDeployer, gameInfo.stakingRewardToken.balanceOf(address(this)));
        }
        gameState.amountToShare = gameInfo.stakingRewardToken.balanceOf(address(this));
    }

    function choseFinalNumber() internal view returns(uint256) {
        for (uint256 i = 0; i<gameInfo.poolNumber;++i){
            if(chosenNumber<gameInfo.pointsPerPool.mul(i.add(1))) return i; 
        }
        return gameInfo.poolNumber;
    }

    function checkFinishGame() internal view returns(bool)  {
        if (block.timestamp >= gameInfo.endTimestamp) return true;
        return false;
    }

    function spreadFunds(uint256 funds_) internal{
        uint256 depositedAmount = gameInfo.stakingRewardToken.balanceOf(address(this));
        gameInfo.stakingRewardToken.safeTransferFrom(_msgSender(), address(this), funds_);
        uint256 amountToSplit = gameInfo.stakingRewardToken.balanceOf(address(this)).sub(depositedAmount); // we do this just in case stakingRewardToken has any kind of transfer Fee
        deposited[_msgSender()] = deposited[_msgSender()].add(amountToSplit);
        uint256 sliceToken = amountToSplit.div(gameInfo.poolNumber);
        uint256 lastPool = gameInfo.poolNumber.sub(1);
        for(uint256 i=0; i<lastPool;++i){
            poolInfo[i].amountAccumulated = poolInfo[i].amountAccumulated.add(sliceToken);
            amountToSplit = amountToSplit.sub(sliceToken);
        }
        poolInfo[lastPool].amountAccumulated = poolInfo[lastPool].amountAccumulated.add(amountToSplit);
    }

    function initializeGameInfo(uint256 poolNumber_, uint256 pointsPerPool_, uint256 depositFee_, uint256 duration_, IBEP20 stakingRewardToken_) internal{
        gameInfo.poolNumber = poolNumber_;
        gameInfo.pointsPerPool = pointsPerPool_;
        gameInfo.depositFee = depositFee_;
        gameInfo.endTimestamp = (block.timestamp).add(duration_);
        gameInfo.stakingRewardToken = stakingRewardToken_;
        gameInfo.gameDeployer = _msgSender();
    }

    // NOT IN PRODUCTION!!!
    //  function timeTravel(uint256 timestamp_) public onlyOwner{
    //     gameInfo.endTimestamp = timestamp_;
    // }


}