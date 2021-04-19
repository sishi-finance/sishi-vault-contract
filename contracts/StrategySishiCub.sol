pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";



import "./interfaces/IController.sol";
import "./interfaces/Token.sol";

interface LionsDen {
  function cub() external view returns (address);
  function devaddr() external view returns (address);
  function cubPerBlock() external view returns (uint256);
  function BONUS_MULTIPLIER() external view returns (uint256);
  function feeAddress() external view returns (address);
  function poolInfo(uint256) external view returns ( address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accCakePerShare );
  function userInfo(uint256, address) external view returns ( uint256 amount, uint256 rewardDebt );
  function totalAllocPoint() external view returns (uint256);
  function startBlock() external view returns (uint256);

  function poolLength() external view returns (uint256);
  function add(uint256 _allocPoint, address _lpToken, uint16 _depositFeeBP, bool _withUpdate) external;
  function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) external;
  function getMultiplier(uint256 _from, uint256 _to) external view returns (uint256);
  function pendingCub(uint256 _pid, address _user) external view returns (uint256);
  function massUpdatePools() external;
  function updatePool(uint256 _pid) external;
  function deposit(uint256 _pid, uint256 _amount) external;
  function withdraw(uint256 _pid, uint256 _amount) external;
  function emergencyWithdraw(uint256 _pid) external;
  function safeZeFiTransfer(address _to, uint256 _amount) external;
  function dev(address _devaddr) external;
  function setFeeAddress(address _feeAddress) external;
  function updateEmissionRate(uint256 _cubPerBlock) external ;
}

interface PancakeSwapRouter {
  function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
  function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

contract StrategySishiCub {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Math for uint256;

    address public constant want = address(0x50D809c74e0B8e49e7B4c65BB3109AbE3Ff4C1C1);
    // address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public constant cubChef = address(0x227e79C83065edB8B954848c46ca50b96CB33E16);
    // address public constant pancakeSwapRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);

    address public governance;
    address public controller;
    address public strategist;

    uint256 public farmPid = 12;
    uint256 public performanceFee = 450;
    uint256 public strategistReward = 50;
    uint256 public withdrawalFee = 50;
    uint256 public harvesterReward = 30;
    uint256 public constant FEE_DENOMINATOR = 10000;

    constructor(address _controller) public {
        governance = msg.sender;
        strategist = msg.sender;
        controller = _controller;
    }

    function getName() external pure returns (string memory) {
        return "StrategySishiCub";
    }

    function deposit() public {
      uint256 _want = IERC20(want).balanceOf(address(this));
      if (_want > 0) {
        _stakeCake();

        _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
          _payFees(_want);
          _stakeCake();
        }
      }
    }

    function _stakeCake() internal {
      uint256 _want = IERC20(want).balanceOf(address(this));
      IERC20(want).safeApprove(cubChef, 0);
      IERC20(want).safeApprove(cubChef, _want);
      LionsDen(cubChef).deposit(farmPid, _want);
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a vault withdrawal
    function withdraw(uint256 _amount) external {
      require(msg.sender == controller, "!controller");
      uint256 _balance = IERC20(want).balanceOf(address(this));
      if (_balance < _amount) {
          _amount = _withdrawSome(_amount.sub(_balance));
          _amount = _amount.add(_balance);
      }

      uint256 _fee = _amount.mul(withdrawalFee).div(FEE_DENOMINATOR);

      IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
      uint256 _want = IERC20(want).balanceOf(address(this));
      LionsDen(cubChef).withdraw(farmPid, _amount);
      _want = IERC20(want).balanceOf(address(this)).sub(_want).sub(_amount);
      if (_want > 0) {
        _payFees(_want);
      }

      return _amount;
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
      require(msg.sender == controller, "!controller");
      _withdrawAll();

      balance = IERC20(want).balanceOf(address(this));

      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
      LionsDen(cubChef).emergencyWithdraw(0);
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfStakedWant() public view returns (uint256) {
      (uint256 _amount,) = LionsDen(cubChef).userInfo(farmPid,address(this));
      return _amount;
    }

    function balanceOfPendingWant() public view returns (uint256) {
      return LionsDen(cubChef).pendingCub(farmPid,address(this));
    }

    function harvest() public returns (uint harvesterRewarded) {
      // require(msg.sender == strategist || msg.sender == governance, "!authorized");
      require(msg.sender == tx.origin, "not eoa");

      _stakeCake();

      uint _want = IERC20(want).balanceOf(address(this));
      if (_want > 0) {
        _payFees(_want);
        uint256 _harvesterReward = _want.mul(harvesterReward).div(FEE_DENOMINATOR);
        IERC20(want).safeTransfer(msg.sender, _harvesterReward);
        _stakeCake();
        return _harvesterReward;
      }
    }

    function _payFees(uint256 _want) internal {
      uint256 _fee = _want.mul(performanceFee).div(FEE_DENOMINATOR);
      uint256 _reward = _want.mul(strategistReward).div(FEE_DENOMINATOR);
      IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
      IERC20(want).safeTransfer(strategist, _reward);
    }

    function balanceOf() public view returns (uint256) {
      return balanceOfWant()
        .add(balanceOfStakedWant()) //will not be correct if we sold syrup
        .add(balanceOfPendingWant());
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setController(address _controller) external {
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }
}
