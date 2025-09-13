// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title VFIDE Token (Lego-Architecture Core)
 * @notice ERC20 with proper burn and modular economics. No pause/blacklist.
 *         Fees/burn are computed by an external IBurnPolicy, and eco-fee is sent
 *         to a single ecoFeeCollector (which later splits to Sanctum/Treasury/Staking/Ops).
 *         Exemptions are resolved via an external IExemptionRegistry.
 *
 * Key properties:
 * - Proper burn: _burn() reduces totalSupply (no "dead wallet" tricks).
 * - If policy fails (reverts/invalid), token falls back to plain transfer (unbrickable).
 * - DAO/multisig can rotate policy/registry/collector addresses; token logic stays immutable.
 * - Emits BurnApplied for transparency & indexing.
 *
 * Compile: Solidity 0.8.30, OZ v5 style (_update).
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IExemptionRegistry {
    function isExempt(address account) external view returns (bool);
}

interface IBurnPolicy {
    /**
     * @dev Returns fee rates for this transfer. Values are in basis points (1e4).
     *      burnBps + ecoFeeBps must be <= policy caps; token still enforces burn+eco <= amount.
     *      Implementations can read ProofScore, Seer surge flags, velocity/size adders, etc.
     */
    function computeBurn(address from, address to, uint256 amount)
        external
        view
        returns (uint16 burnBps, uint16 ecoFeeBps);

    /// @dev Optional: lets UIs see if policy considers the system in "surge".
    function isSurge() external view returns (bool);
}

/**
 * @dev Minimal interface for an eco-fee sink. Token only transfers to this address.
 * The collector will later split funds to Sanctum/Treasury/Staking/Ops (DAO-configurable).
 */
interface IEcoFeeCollector {
    // Optional hook; token does not require this call to succeed.
    function onFeeReceived(address token, address from, uint256 amount) external;
}

contract VFIDEToken is ERC20, ERC20Permit, Ownable2Step {
    // ---------------------------- Constants ----------------------------
    uint256 public constant MAX_SUPPLY = 200_000_000e18; // 200M fixed

    // --------------------------- Governance ----------------------------
    IExemptionRegistry public exemptionRegistry;
    IBurnPolicy public burnPolicy;
    address public ecoFeeCollector; // single sink; collector later splits to beneficiaries

    // ----------------------------- Events ------------------------------
    event BurnApplied(address indexed from, address indexed to, uint256 burned, uint256 ecoFee);
    event PolicyUpdated(address indexed oldPolicy, address indexed newPolicy);
    event ExemptionRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event EcoFeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);

    // --------------------------- Construction --------------------------
    /**
     * @param _owner            Initial owner (DAO/multisig deployer)
     * @param _initialReceiver  Address to receive the pre-minted MAX_SUPPLY
     */
    constructor(address _owner, address _initialReceiver)
        ERC20("VFIDE", "VFIDE")
        ERC20Permit("VFIDE")
    {
        require(_owner != address(0) && _initialReceiver != address(0), "Zero address");
        _transferOwnership(_owner);
        _mint(_initialReceiver, MAX_SUPPLY);
    }

    // ----------------------- Admin (DAO) setters -----------------------
    function setExemptionRegistry(IExemptionRegistry reg) external onlyOwner {
        emit ExemptionRegistryUpdated(address(exemptionRegistry), address(reg));
        exemptionRegistry = reg;
    }

    function setBurnPolicy(IBurnPolicy policy) external onlyOwner {
        emit PolicyUpdated(address(burnPolicy), address(policy));
        burnPolicy = policy;
    }

    function setEcoFeeCollector(address collector) external onlyOwner {
        require(collector != address(0), "Zero collector");
        emit EcoFeeCollectorUpdated(ecoFeeCollector, collector);
        ecoFeeCollector = collector;
    }

    // --------------------------- Core logic ----------------------------
    /**
     * @dev OZ v5 transfer/mint/burn funnel. We override to insert the fee/burn path.
     *      Rules:
     *        - Mint/burn paths fall through to super (when from==0 or to==0).
     *        - If either side is exempt, skip policy and do plain transfer.
     *        - Otherwise:
     *           * Ask burnPolicy for (burnBps, ecoFeeBps) via staticcall (try/catch).
     *           * Proper burn using _burn(from, burnAmt) – reduces totalSupply.
     *           * Transfer eco-fee to ecoFeeCollector (single sink).
     *           * Transfer remainder to recipient.
     *        - On policy failure, fallback to plain transfer.
     */
    function _update(address from, address to, uint256 value) internal override {
        // Mint or direct burn path
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // If not configured or exempt, plain transfer
        if (
            address(burnPolicy) == address(0) ||
            address(exemptionRegistry) == address(0) ||
            _isExempt(from) || _isExempt(to)
        ) {
            super._update(from, to, value);
            return;
        }

        // Ask the policy for fee rates; never let policy brick the token
        (bool ok, bytes memory data) = address(burnPolicy).staticcall(
            abi.encodeWithSelector(IBurnPolicy.computeBurn.selector, from, to, value)
        );

        if (!ok || data.length < 64) {
            // Policy failed: fallback to plain transfer
            super._update(from, to, value);
            return;
        }

        (uint16 burnBps, uint16 ecoBps) = abi.decode(data, (uint16, uint16));

        // Calculate amounts (basis points, 1e4)
        uint256 burnAmt = (value * uint256(burnBps)) / 10_000;
        uint256 ecoAmt  = (value * uint256(ecoBps)) / 10_000;

        // Cap: burn + eco <= value
        unchecked {
            uint256 maxEco = value - burnAmt;
            if (ecoAmt > maxEco) {
                ecoAmt = maxEco;
            }
        }

        // 1) Proper burn (reduces totalSupply)
        if (burnAmt != 0) {
            // _burn will internally call _update(from, address(0), burnAmt)
            _burn(from, burnAmt);
        }

        // 2) Eco-fee to collector (single sink) – optional hook best-effort
        uint256 sentToCollector = 0;
        if (ecoAmt != 0 && ecoFeeCollector != address(0)) {
            super._update(from, ecoFeeCollector, ecoAmt);
            sentToCollector = ecoAmt;

            // Best-effort notify (never revert token transfer if collector hook fails)
            (bool callOk, ) = ecoFeeCollector.call(
                abi.encodeWithSelector(IEcoFeeCollector.onFeeReceived.selector, address(this), from, ecoAmt)
            );
            callOk; // ignore result
        }

        // 3) Remainder to recipient
        uint256 remainder;
        unchecked {
            remainder = value - burnAmt - sentToCollector;
        }
        super._update(from, to, remainder);

        emit BurnApplied(from, to, burnAmt, sentToCollector);
    }

    // -------------------------- View helpers ---------------------------
    function _isExempt(address a) internal view returns (bool) {
        // If registry unset, conservatively treat as non-exempt (handled above).
        return address(exemptionRegistry) != address(0) && exemptionRegistry.isExempt(a);
    }

    // -------------------------- Rescue (safe) --------------------------
    /**
     * @notice Rescue non-VFIDE tokens or ETH accidentally sent to this contract.
     *         Does NOT allow rescuing VFIDE itself.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero to");
        require(token != address(this), "No VFIDE");
        (bool s, bytes memory r) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(s && (r.length == 0 || abi.decode(r, (bool))), "Rescue failed");
    }

    receive() external payable {}
}