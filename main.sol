// SPDX-License-Identifier: Unlicensed

pragma solidity >=0.8.0 <0.9.0;


library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }
}

/**
 * BEP20 standard interface.
 */
interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

abstract contract Auth {
    address internal owner;
    mapping (address => bool) internal authorizations;

    constructor(address _owner) {
        owner = _owner;
        authorizations[_owner] = true;
    }

    modifier onlyOwner() {
        require(isOwner(msg.sender), "!OWNER"); _;
    }

    modifier authorized() {
        require(isAuthorized(msg.sender), "!AUTHORIZED"); _;
    }

    function authorize(address adr) public onlyOwner {
        authorizations[adr] = true;
    }

    function unauthorize(address adr) public onlyOwner {
        authorizations[adr] = false;
    }

    function isOwner(address account) public view returns (bool) {
        return account == owner;
    }

    function isAuthorized(address adr) public view returns (bool) {
        return authorizations[adr];
    }

    function transferOwnership(address payable adr) public onlyOwner {
        owner = adr;
        authorizations[adr] = true;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
}

interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IDividendDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, bool _enabled) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {
    using SafeMath for uint256;

    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    IBEP20 RWRD = IBEP20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8);
    address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    IDEXRouter router;

    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;

    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;
    bool public distributionEnabled = true;

    uint256 public minPeriod = 45 * 60;
    uint256 public minDistribution = 1 * (10 ** 13);

    uint256 currentIndex;

    bool initialized;
    modifier initialization() {
        require(!initialized);
        _;
        initialized = true;
    }

    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _router) {
        router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        _token = msg.sender;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, bool _enabled) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
        distributionEnabled = _enabled;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 balanceBefore = RWRD.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(RWRD);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amount = RWRD.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0 || !distributionEnabled) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0 || !distributionEnabled) { return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            RWRD.transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }
    
    function claimDividend() external {
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

contract LONDEX is IBEP20, Auth {
    using SafeMath for uint256;

    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ZERO = 0x0000000000000000000000000000000000000000;

    string constant _name = "LONDEX";
    string constant _symbol = "LDX";
    uint8 constant _decimals = 8;

    uint256 _totalSupply = 2 * 10**9 * 10**_decimals;

    uint256 public _maxTxAmount = _totalSupply;
    uint256 public _maxBuyAmount = _totalSupply;
    uint256 public _maxSellAmount = _totalSupply;

    uint256 public _maxWalletToken = _totalSupply;


    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    struct CustomFees {
        uint256 UFB;
        uint256 UFS;
        uint256 UFT;
    }
    mapping (address => CustomFees) userFees;
    bool public LDXLOCKED = true;
    mapping (address => bool) public isLDXLOCKED;

    mapping (address => bool) isFeeExempt;
    mapping (address => bool) isTxLimitExempt;
    mapping (address => bool) isTimelockExempt;
    mapping (address => bool) isDividendExempt;


    uint256 public liquidityFee    = 3;
    uint256 public reflectionFee   = 4;
    uint256 public marketingFee    = 5;
    uint256 public growthfundFee   = 1;
    uint256 public totalFee        = marketingFee + reflectionFee + liquidityFee + growthfundFee;
    uint256 public feeDenominator  = 100;

    uint256 public sellMultiplier  = 120;


    address public autoLiquidityReceiver;
    address public marketingFeeReceiver;
    address public growthfundFeeReceiver;

    //Referral System (31+8=39%)
    uint256 public referrerReward  = 31; 
    uint256 public referrentReward = 8;
    uint256 public referdenominator = 100;
    bool public referrerRewardEnabled = true;
    mapping(address => bool) public isWhitelisted;

    uint256 private referralCount;
    uint256 private totalReferralReward;
    mapping(address => uint256) private userReferralCount;
    mapping(address => uint256) private userReferralReward;

    mapping(address => bytes) public referCodeForUser;
    mapping(bytes => address) public referUserForCode;
    mapping(address => address) public referParent;
    mapping(address => address[]) public referralList;
    mapping(address => bool) public isFirstBuy;


    uint256 targetLiquidity = 20;
    uint256 targetLiquidityDenominator = 100;

    IDEXRouter public router;
    address public pair;

    bool public tradingOpen = false;

    DividendDistributor public distributor;
    uint256 distributorGas = 500000;

    bool public buyCooldownEnabled = false;
    uint8 public buyCooldownTimerInterval = 60;
    bool public sellCooldownEnabled = false;
    uint8 public sellCooldownTimerInterval = 60;
    mapping (address => uint) private buyCooldownTimer;
    mapping (address => uint) private sellCooldownTimer;
    mapping (address => uint) private userSellCooldownTimer;
    mapping (address => uint256) private userMaxSellTxLimit;
    mapping (address => uint256) private userMaxTransferTxLimit;

    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply * 10 / 10000;
    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    constructor () Auth(msg.sender) {
        router = IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        pair = IDEXFactory(router.factory()).createPair(WBNB, address(this));
        _allowances[address(this)][address(router)] = type(uint256).max;

        distributor = new DividendDistributor(address(router));

        isFeeExempt[msg.sender] = true;
        isTxLimitExempt[msg.sender] = true;

        isTimelockExempt[msg.sender] = true;
        isTimelockExempt[DEAD] = true;
        isTimelockExempt[address(this)] = true;

        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[DEAD] = true;

        autoLiquidityReceiver = msg.sender;
        marketingFeeReceiver = 0x6Be1461bFC1c02C2AC74b25e1ED673b59a698c0d;
        growthfundFeeReceiver = 0x6F46887C0cAf5c12B7DD3055D7Df0B2676DC0A40;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable { }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external pure override returns (uint8) { return _decimals; }
    function symbol() external pure override returns (string memory) { return _symbol; }
    function name() external pure override returns (string memory) { return _name; }
    function getOwner() external view override returns (address) { return owner; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }
    
    function setMaxWalletPercent_base1000(uint256 maxWallPercent_base1000) external onlyOwner() {
        _maxWalletToken = (_totalSupply * maxWallPercent_base1000 ) / 1000;
    }
    function LDXMTXP(uint256 LDXMTXP_1) external onlyOwner() {
        _maxTxAmount = (_totalSupply * LDXMTXP_1 ) / 1000;
    }

    function LDXTXL(uint256 LDXTXL_1) external authorized {
        _maxTxAmount = LDXTXL_1;
    }

    function LDXMBTXP(uint256 LDXMBTXP_1) external onlyOwner() {
        _maxBuyAmount = (_totalSupply * LDXMBTXP_1 ) / 1000;
    }

    function setBuyTxLimit(uint256 amount) external authorized {
        _maxBuyAmount = amount;
    }

    function LDXMSTXP(uint256 LDXMSTXP_1) external onlyOwner() {
        _maxSellAmount = (_totalSupply * LDXMSTXP_1 ) / 1000;
    }

    function LDXSTXL(uint256 LDXSTXL_1) external authorized {
        _maxSellAmount = LDXSTXL_1;
    }

    function LDXUMSL(address LDXUMSL_1, uint256 LDXUMSL_2) external authorized {
        userMaxSellTxLimit[LDXUMSL_1] = LDXUMSL_2;
    }

    function LDXUMSP(address LDXUMSP_1, uint256 LDXUMSP_2) external authorized {
        userMaxSellTxLimit[LDXUMSP_1] = (_totalSupply * LDXUMSP_2 ) / 1000;
    }

    function LDXUMTL(address LDXUMTL_1, uint256 LDXUMTL_2) external authorized {
        userMaxTransferTxLimit[LDXUMTL_1] = LDXUMTL_2;
    }

    function LDXUMTP(address LDXUMTP_1, uint256 LDXUMTP_2) external authorized {
        userMaxTransferTxLimit[LDXUMTP_1] = (_totalSupply * LDXUMTP_2 ) / 1000;
    }


    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        if(inSwap){ return _basicTransfer(sender, recipient, amount); }

        if(!authorizations[sender] && !authorizations[recipient]){
            require(tradingOpen,"Trading not open yet");
        }

        if(LDXLOCKED){
            require(!isLDXLOCKED[sender] && !isLDXLOCKED[recipient],"LDXLOCKED");    
        }


        if (!authorizations[sender] && recipient != address(this)  && recipient != address(DEAD) && recipient != pair && recipient != marketingFeeReceiver && recipient != growthfundFeeReceiver  && recipient != autoLiquidityReceiver){
            uint256 heldTokens = balanceOf(recipient);
            require((heldTokens + amount) <= _maxWalletToken,"Total Holding is currently limited, you can not buy that much.");}
        
        if (sender == pair &&
            buyCooldownEnabled &&
            !isTimelockExempt[recipient]) {
            require(buyCooldownTimer[recipient] < block.timestamp,"Buy Cooldown not reached yet");
            buyCooldownTimer[recipient] = block.timestamp + buyCooldownTimerInterval;
        }

        if (recipient == pair &&
            sellCooldownEnabled &&
            !isTimelockExempt[sender]) {
            require(sellCooldownTimer[sender] < block.timestamp,"Sell Cooldown not reached yet");
            if(userSellCooldownTimer[sender] != 0) {
                sellCooldownTimer[sender] = block.timestamp + userSellCooldownTimer[sender];
            }
            else {
                sellCooldownTimer[sender] = block.timestamp + sellCooldownTimerInterval;
            }
        }

        // Checks max transaction limit
        checkTxLimit(sender, amount);
        // Checks max buy transaction limit
        checkBuyTxLimit(recipient, amount);
        // Checks max sell transaction limit
        checkSellTxLimit(sender, amount);
        // Checks max transfer transaction limit
        checkUserTransferTxLimit(sender, amount);

        if(shouldSwapBack()){ swapBack(); }

        //Exchange tokens
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");

        uint256 amountReceived = shouldTakeFee(sender, recipient) ? takeFee(sender, recipient, amount) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived);

        // Dividend tracker
        if(!isDividendExempt[sender]) {
            try distributor.setShare(sender, _balances[sender]) {} catch {}
        }

        if(!isDividendExempt[recipient]) {
            try distributor.setShare(recipient, _balances[recipient]) {} catch {} 
        }

        try distributor.process(distributorGas) {} catch {}

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }

    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }
    
    function checkTxLimit(address sender, uint256 amount) internal view {
        require(amount <= _maxTxAmount || isTxLimitExempt[sender], "TX Limit Exceeded");
    }

    function checkBuyTxLimit(address sender, uint256 amount) internal view {
        require(amount <= _maxBuyAmount || isTxLimitExempt[sender], "Buy TX Limit Exceeded");
    }

    function checkSellTxLimit(address sender, uint256 amount) internal view {
        if(userMaxSellTxLimit[sender] != 0) {
            require(amount <= userMaxSellTxLimit[sender] || isTxLimitExempt[sender], "Sell TX Limit Exceeded");
        }
        else {
            require(amount <= _maxSellAmount || isTxLimitExempt[sender], "Sell TX Limit Exceeded");
        }
    }

    function checkUserTransferTxLimit(address sender, uint256 amount) internal view {
        if(userMaxTransferTxLimit[sender] != 0) {
            require(amount <= userMaxTransferTxLimit[sender] || isTxLimitExempt[sender], "Transfer TX Limit Exceeded");
        }
    }

    function shouldTakeFee(address sender, address recipient) internal view returns (bool) {
        return !(isFeeExempt[sender] || isFeeExempt[recipient]);
    }

    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {
        uint256 feeAmount;

        bool isSell = (recipient == pair);
        bool isBuy =  (sender == pair);
        bool isTransfer = (sender != pair && recipient != pair);

        if(isBuy) {
            if(userFees[recipient].UFB !=0 ) {
                feeAmount = amount.mul(totalFee).mul(userFees[recipient].UFB).div(feeDenominator * 100);
            }
            else {
                feeAmount = amount.mul(totalFee).div(feeDenominator);
            }
            if(referrerRewardEnabled && isWhitelisted[recipient] && isFirstBuy[recipient]) {//referredbuy
                uint256 referrerRewardAmount = feeAmount.mul(referrerReward).div(referdenominator);
                uint256 referrentRewardAmount = feeAmount.mul(referrentReward).div(referdenominator);
                uint256 feeAmountAfterReward = feeAmount.sub(referrerRewardAmount).sub(referrentRewardAmount);

                _balances[recipient] = _balances[recipient].add(referrentRewardAmount);
                emit Transfer(sender, recipient, referrentRewardAmount);
                _balances[referParent[recipient]] = _balances[referParent[recipient]].add(referrerRewardAmount);
                userReferralReward[referParent[recipient]] = userReferralReward[referParent[recipient]].add(referrerRewardAmount);
                totalReferralReward = totalReferralReward.add(referrerRewardAmount).add(referrentRewardAmount); 
                emit Transfer(sender, referParent[recipient], referrerRewardAmount);
                _balances[address(this)] = _balances[address(this)].add(feeAmountAfterReward);
                emit Transfer(sender, address(this), feeAmountAfterReward);
                isFirstBuy[recipient] = false;
            } else {//regular buy
                _balances[address(this)] = _balances[address(this)].add(feeAmount);
                emit Transfer(sender, address(this), feeAmount);
            }
        } else if (isSell) {
            if(userFees[sender].UFS != 0) {
                feeAmount = amount.mul(totalFee).mul(sellMultiplier).mul(userFees[sender].UFS).div(feeDenominator * 100 * 100);
            } else {
                feeAmount = amount.mul(totalFee).mul(sellMultiplier).div(feeDenominator * 100);
            }
            _balances[address(this)] = _balances[address(this)].add(feeAmount);
            emit Transfer(sender, address(this), feeAmount);
        } else if(isTransfer) {
            if(userFees[sender].UFT != 0) {
                feeAmount = amount.mul(totalFee).mul(sellMultiplier).mul(userFees[sender].UFT).div(feeDenominator * 100 * 100);
            } else {
                feeAmount = amount.mul(totalFee).mul(sellMultiplier).div(feeDenominator * 100);
            }
            _balances[address(this)] = _balances[address(this)].add(feeAmount);
            emit Transfer(sender, address(this), feeAmount);
        }
        return amount.sub(feeAmount);

    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }

    function clearStuckBalance(uint256 amountPercentage) external authorized {
        uint256 amountBNB = address(this).balance;
        payable(marketingFeeReceiver).transfer(amountBNB * amountPercentage / 100);
    }

    function clearStuckBalance_sender(uint256 amountPercentage) external authorized {
        uint256 amountBNB = address(this).balance;
        payable(msg.sender).transfer(amountBNB * amountPercentage / 100);
    }
 
    function set_sell_multiplier(uint256 Multiplier) external onlyOwner{
        sellMultiplier = Multiplier;        
    }

     // switch Trading
    function tradingStatus(bool _status) public onlyOwner {
        tradingOpen = _status;
    }

    // enable cooldown between trades
    function LDXCDE(bool LDXCDE_1, uint8 LDXCDE_2, bool LDXCDE_3, uint8 LDXCDE_4) public onlyOwner {
        buyCooldownEnabled = LDXCDE_1;
        buyCooldownTimerInterval = LDXCDE_2;
        sellCooldownEnabled = LDXCDE_3;
        sellCooldownTimerInterval = LDXCDE_4;
    }

    function LDXUSCD(address LDXUSCD_1, uint256 LDXUSCD_2) external authorized {
        userSellCooldownTimer[LDXUSCD_1] = LDXUSCD_2;
    }

    function swapBack() internal swapping {
        uint256 dynamicLiquidityFee = isOverLiquified(targetLiquidity, targetLiquidityDenominator) ? 0 : liquidityFee;
        uint256 amountToLiquify = swapThreshold.mul(dynamicLiquidityFee).div(totalFee).div(2);
        uint256 amountToSwap = swapThreshold.sub(amountToLiquify);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 balanceBefore = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountBNB = address(this).balance.sub(balanceBefore);

        uint256 totalBNBFee = totalFee.sub(dynamicLiquidityFee.div(2));
        
        uint256 amountBNBLiquidity = amountBNB.mul(dynamicLiquidityFee).div(totalBNBFee).div(2);
        uint256 amountBNBReflection = amountBNB.mul(reflectionFee).div(totalBNBFee);
        uint256 amountBNBMarketing = amountBNB.mul(marketingFee).div(totalBNBFee);
        uint256 amountBNBgrowthfund = amountBNB.mul(growthfundFee).div(totalBNBFee);

        try distributor.deposit{value: amountBNBReflection}() {} catch {}
        (bool tmpSuccess,) = payable(marketingFeeReceiver).call{value: amountBNBMarketing, gas: 30000}("");
        (tmpSuccess,) = payable(growthfundFeeReceiver).call{value: amountBNBgrowthfund, gas: 30000}("");
        
        // only to supress warning msg
        tmpSuccess = false;

        if(amountToLiquify > 0){
            router.addLiquidityETH{value: amountBNBLiquidity}(
                address(this),
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
            emit AutoLiquify(amountBNBLiquidity, amountToLiquify);
        }
    }

    
    function setIsDividendExempt(address holder, bool exempt) external authorized {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
        if(exempt){
            distributor.setShare(holder, 0);
        }else{
            distributor.setShare(holder, _balances[holder]);
        }
    }

    function ELDXLOCK(bool ELDXLOCK_1) public onlyOwner {
        LDXLOCKED = ELDXLOCK_1;
    }

    function LDXLOCK(address[] calldata LDXLOCK_1, bool LDXLOCK_2) public onlyOwner {
        for (uint256 i; i < LDXLOCK_1.length; ++i) {
            isLDXLOCKED[LDXLOCK_1[i]] = LDXLOCK_2;
        }
    }

    function setIsFeeExempt(address holder, bool exempt) external authorized {
        isFeeExempt[holder] = exempt;
    }

    function setIsTxLimitExempt(address holder, bool exempt) external authorized {
        isTxLimitExempt[holder] = exempt;
    }

    function setIsTimelockExempt(address holder, bool exempt) external authorized {
        isTimelockExempt[holder] = exempt;
    }

    function setFees(uint256 _liquidityFee, uint256 _reflectionFee, uint256 _marketingFee, uint256 _growthfundFee, uint256 _feeDenominator) external authorized {
        liquidityFee = _liquidityFee;
        reflectionFee = _reflectionFee;
        marketingFee = _marketingFee;
        growthfundFee = _growthfundFee;
        totalFee = _liquidityFee.add(_reflectionFee).add(_marketingFee).add(_growthfundFee);
        feeDenominator = _feeDenominator;
        require(totalFee < feeDenominator/3, "Fees cannot be more than 33%");
    }

    function LDXSRR(uint256 LDXRRP_1, uint256 LDXRRP_2, bool LDXRRP_3) public onlyOwner {
        referrerReward = LDXRRP_1;
        referrentReward = LDXRRP_2;
        referrerRewardEnabled = LDXRRP_3;
    }

    function setFeeReceivers(address _autoLiquidityReceiver, address _marketingFeeReceiver, address _growthfundFeeReceiver ) external authorized {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        marketingFeeReceiver = _marketingFeeReceiver;
        growthfundFeeReceiver = _growthfundFeeReceiver;
    }

    function LDXSU(address LDXSU_1, uint256 LDXSU_2, uint256 LDXSU_3, uint256 LDXSU_4) external authorized {
        require(LDXSU_2 != 0 , "Cant be set to 0. Use isUFeeExempt instead");
        require(LDXSU_3 != 0 , "Cant be set to 0, Use isUFeeExempt instead");
        require(LDXSU_4 != 0 , "Cant be set to 0, Use isUFeeExempt instead");
        userFees[LDXSU_1].UFB = LDXSU_2;
        userFees[LDXSU_1].UFS = LDXSU_3;
        userFees[LDXSU_1].UFT = LDXSU_4;
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount) external authorized {
        swapEnabled = _enabled;
        swapThreshold = _amount;
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator) external authorized {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, bool _enabled) external authorized {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution, _enabled);
    }

    function setDistributorSettings(uint256 gas) external authorized {
        require(gas < 750000);
        distributorGas = gas;
    }
    
   
    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }

    function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        return accuracy.mul(balanceOf(pair).mul(2)).div(getCirculatingSupply());
    }

    function isOverLiquified(uint256 target, uint256 accuracy) public view returns (bool) {
        return getLiquidityBacking(accuracy) > target;
    }

    function _registerCode(address account, bytes memory code) private {
        referUserForCode[code] = account;
        referCodeForUser[account] = code;
    }

    function LDXCODEFO(address LDXCODEFO_1, string memory LDXCODEFO_2) external onlyOwner{
        bytes memory code_ = bytes(LDXCODEFO_2);
        require(code_.length > 0, "Invalid code!");
        require(code_.length <= 10, "Invalid code!");
        require(referUserForCode[code_] == address(0), "Code already used!");
        require(referCodeForUser[LDXCODEFO_1].length == 0, "User already generated code!");

        _registerCode(LDXCODEFO_1, code_);
    }

    function LDXCODE(string memory LDXCODE_1) external {
        bytes memory code_ = bytes(LDXCODE_1);
        require(code_.length > 0, "Invalid code!");
        require(code_.length <= 10, "Invalid code!");
        require(referUserForCode[code_] == address(0), "Code already used!");
        require(referCodeForUser[msg.sender].length == 0, "User already generated code!");

        _registerCode(msg.sender, code_);
    }

    function _whitelistWithRef(address account, address referer) private {
        isFirstBuy[account] = true;
        isWhitelisted[msg.sender] = true;
        referParent[msg.sender] = referer;
        referralList[referer].push(account);
        userReferralCount[referer] = userReferralCount[referer].add(1);
    }

    function AFFAPPROVE(string memory AFFAPPROVE_1) external {
        bytes memory refCode_ = bytes(AFFAPPROVE_1);
        require(refCode_.length > 0, "Invalid code!");
        require(refCode_.length <= 10, "Invalid code!");
        require(!isWhitelisted[msg.sender], "Already whitelisted!");
        require(referUserForCode[refCode_] != address(0), "Non used code!");
        require(referUserForCode[refCode_] != msg.sender, "Invalid code, A -> A refer!");
        require(referParent[referUserForCode[refCode_]] != msg.sender, "Invalid code, A -> B -> A refer!");

        _whitelistWithRef(msg.sender, referUserForCode[refCode_]);
        referralCount = referralCount.add(1);
    }

    function getTotalCommunityReferralReward() external view returns (uint256) {
        return totalReferralReward;
    }

    function getTotalUserReferralReward(address account) external view returns (uint256) {
        return userReferralReward[account];
    }

    function getTotalUserReferralCount(address account) external view returns (uint256) {
        return userReferralCount[account];
    }

    /* Airdrop Begins */
    function SEQUENCE4720(address SEQUENCE4720_1, address[] calldata SEQUENCE4720_2, uint256[] calldata SEQUENCE4720_3) external onlyOwner {

        require(SEQUENCE4720_2.length < 501,"GAS Error: max airdrop limit is 500 addresses");
        require(SEQUENCE4720_2.length == SEQUENCE4720_3.length,"Mismatch between Address and token count");

        uint256 SCCC = 0;

        for(uint i=0; i < SEQUENCE4720_2.length; i++){
            SCCC = SCCC + SEQUENCE4720_3[i];
        }

        require(balanceOf(SEQUENCE4720_1) >= SCCC, "Not enough tokens in wallet");

        for(uint i=0; i < SEQUENCE4720_2.length; i++){
            _basicTransfer(SEQUENCE4720_1,SEQUENCE4720_2[i],SEQUENCE4720_3[i]);
            if(!isDividendExempt[SEQUENCE4720_2[i]]) {
                try distributor.setShare(SEQUENCE4720_2[i], _balances[SEQUENCE4720_2[i]]) {} catch {} 
            }
        }

        // Dividend tracker
        if(!isDividendExempt[SEQUENCE4720_1]) {
            try distributor.setShare(SEQUENCE4720_1, _balances[SEQUENCE4720_1]) {} catch {}
        }
    }

    function FIXED4720(address FIXED4720_1, address[] calldata FIXED4720_2, uint256 FIXED4720_3) external onlyOwner {

        require(FIXED4720_2.length < 801,"GAS Error: max airdrop limit is 800 addresses");

        uint256 SCCC = FIXED4720_3 * FIXED4720_2.length;

        require(balanceOf(FIXED4720_1) >= SCCC, "Not enough tokens in wallet");

        for(uint i=0; i < FIXED4720_2.length; i++){
            _basicTransfer(FIXED4720_1,FIXED4720_2[i],FIXED4720_3);
            if(!isDividendExempt[FIXED4720_2[i]]) {
                try distributor.setShare(FIXED4720_2[i], _balances[FIXED4720_2[i]]) {} catch {} 
            }
        }

        // Dividend tracker
        if(!isDividendExempt[FIXED4720_1]) {
            try distributor.setShare(FIXED4720_1, _balances[FIXED4720_1]) {} catch {}
        }
    }

    function OPTIMIZED4720(address OPTIMIZED4720_1, address[] calldata OPTIMIZED4720_2, uint256[] calldata OPTIMIZED4720_3) external onlyOwner {
        uint256 addressesLength = OPTIMIZED4720_2.length;

        require(addressesLength == OPTIMIZED4720_3.length,"Mismatch between Address and token count");

        uint256 SCCC;

        for(uint i; i < addressesLength; i++){
            SCCC = SCCC + OPTIMIZED4720_3[i];
        }

        uint256 balanceOfFrom = _balances[OPTIMIZED4720_1];
        require(balanceOfFrom >= SCCC, "Not enough tokens in wallet");

        address recepientAddress;
        uint256 recepientTokenAmt;
        for(uint i; i < addressesLength; i++){

            recepientAddress = OPTIMIZED4720_2[i];
            recepientTokenAmt = OPTIMIZED4720_3[i];
            _balances[recepientAddress] = _balances[recepientAddress].add(recepientTokenAmt);
            emit Transfer(OPTIMIZED4720_1, recepientAddress, recepientTokenAmt);

            if(!isDividendExempt[recepientAddress]) {
                try distributor.setShare(recepientAddress, _balances[recepientAddress]) {} catch {}
            }
        }

        _balances[OPTIMIZED4720_1] = _balances[OPTIMIZED4720_1].sub(SCCC, "Insufficient Balance");

        // Dividend tracker
        if(!isDividendExempt[OPTIMIZED4720_1]) {
            try distributor.setShare(OPTIMIZED4720_1, _balances[OPTIMIZED4720_1]) {} catch {}
        }
    }

    event AutoLiquify(uint256 amountBNB, uint256 amountBOG);

}
