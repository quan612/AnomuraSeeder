// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import { LicenseVersion, CantBeEvil } from "./CantBeEvil.sol";
import { IAnomuraEquipment } from "./interfaces/IAnomuraEquipment.sol";
import { IEquipmentData } from "./EquipmentData.sol";
import { IAnomuraEquipment, EquipmentMetadata, EquipmentType, EquipmentRarity } from "./interfaces/IAnomuraEquipment.sol";

import {IAnomuraSeeder} from "./interfaces/IAnomuraSeeder.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

contract AnomuraSeeder is IAnomuraSeeder, VRFConsumerBaseV2, AccessControlEnumerable, CantBeEvil, AutomationCompatibleInterface  {

    IEquipmentData public equipmentData;
    IAnomuraEquipment public equipmentContract;

    address _automationRegistry;
    // using EnumerableSet for EnumerableSet.UintSet;
    VRFCoordinatorV2Interface _coordinator;
    bytes32 private immutable _keyHash;
    bytes32 private constant SEEDER_ROLE = keccak256("SEEDER_ROLE");

    uint32 private constant CALLBACK_GAS_LIMIT = 240000;
    uint32 private constant NUM_WORDS = 1;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;

    uint256 public constant BATCH_SIZE=50;
    uint64 private _subscriptionId;

    mapping(uint256 => uint256) private _requestIdToGeneration;

    // genId => seed
    mapping(uint256 => uint256) private genSeed;

    /// @notice emitted when a random number is returned from Vrf callback
    /// @param requestId the request identifier, initially returned by {requestRandomness}
    /// @param randomness random number generated by chainlink vrf
    event RequestSeedFulfilled(uint256 indexed requestId, uint256 randomness);

    constructor(
        address coordinator_,
        bytes32 keyHash_,
        uint64 subscriptionId_,
        address equipmentData_
    )
        // IEquipmentData _equipmentData,
        VRFConsumerBaseV2(address(coordinator_))
        CantBeEvil(LicenseVersion.PUBLIC)
    {
        _coordinator = VRFCoordinatorV2Interface(address(coordinator_));
        _keyHash = keyHash_;
        _subscriptionId = subscriptionId_;
        equipmentData = IEquipmentData(equipmentData_);

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());    
    }

    function requestSeed(uint256 _generationId)
        external
        onlyRole(SEEDER_ROLE)
        returns (uint256 requestId)
    {
        if(equipmentContract.totalSupply() == 0){
            revert("No token minted yet.");
        }
        uint256 divider = equipmentContract.totalSupply() / BATCH_SIZE;

        if(_generationId < 1 || _generationId > divider + 1){
            revert("Invalid Generation Id");
        }
        if(genSeed[_generationId] != 0){
            revert("Seed already requested!");
        }
        requestId = _coordinator.requestRandomWords(
            _keyHash,
            _subscriptionId,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );

        _requestIdToGeneration[requestId] = _generationId;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override 
    {
        uint256 _generationId = _requestIdToGeneration[requestId];
     
        genSeed[_generationId] = randomWords[0];
        emit RequestSeedFulfilled(_generationId, randomWords[0]);
    }

    /* @dev This function is only used in case of migration, when the seeder contract turns wrong, and we want to reuse the seed generated previously so we can set it up on the new deployment.
     *  @params _generationId Id of the generation
     *  @params _seed from chainlink vrf
     */
    function setSeedForGenerationByAdmin(uint256 _generationId, uint256 _seed) external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if( genSeed[_generationId] != 0) revert("Seed set");
        genSeed[_generationId] = _seed;
        emit RequestSeedFulfilled(_generationId, _seed);
    }

    /* @dev This function is for user to set their own meta data, given the seed is fulfilled by Chainlink, instead of waiting for us to set for them
     * @params _tokenId Id of the token
     */
    function setMetadataForToken(uint256 _tokenId) external {
        require(address(equipmentContract)  != address(0x0), "Equipment contract not set");
        require(equipmentContract.isTokenExists(_tokenId), "Token not exists");

        uint256 _generationId = getGenerationOfToken(_tokenId);
        uint256 _generationSeed = genSeed[_generationId];

        require(_generationSeed != 0, "Seed not set for gen");

        uint256 _seedForThisToken = uint256(keccak256(abi.encode(_generationSeed, _tokenId)));
        string memory equipmentName;
        EquipmentRarity rarity;
        EquipmentType typeOf = equipmentData.pluckType(_seedForThisToken);

        if (typeOf == EquipmentType.BODY) {
            (equipmentName, rarity) = equipmentData.pluckBody(_seedForThisToken);
        } else if (typeOf == EquipmentType.CLAWS) {
            (equipmentName, rarity) = equipmentData.pluckClaws(_seedForThisToken);
        } else if (typeOf == EquipmentType.LEGS) {
            (equipmentName, rarity) = equipmentData.pluckLegs(_seedForThisToken);
        } else if (typeOf == EquipmentType.SHELL) {
            (equipmentName, rarity) = equipmentData.pluckShell(_seedForThisToken);
        } else if (typeOf == EquipmentType.HABITAT) {
            (equipmentName, rarity) = equipmentData.pluckHabitat(_seedForThisToken);
        } else if (typeOf == EquipmentType.HEADPIECES) {
            (equipmentName, rarity) = equipmentData.pluckHeadpieces(_seedForThisToken);
        } else {
            revert InvalidValue();
        }

        EquipmentMetadata memory metaData = EquipmentMetadata({
                    name: equipmentName,
                    equipmentRarity: rarity,
                    equipmentType: typeOf,
                    isSet: true
                });

        bytes memory _dataToSet = abi.encode(_tokenId, metaData);
        equipmentContract.setMetaDataForToken(_dataToSet);
    }

    function getGenerationOfToken(uint256 _tokenId) public view returns(uint256){
        if(!equipmentContract.isTokenExists(_tokenId)){
            return 0;
        }

        uint256 divider = _tokenId / BATCH_SIZE;
        return divider + 1;
    }

    /**
      @dev This is the starting point of contract automation.
      This function to be called by Gelato, or Chainlink to verify the integrity of callData being passed on.
      Then it reads the metadata to be set for token range from another contract that stores the attributes
      Then if everything is good, it returns a flag either true of false to instruct gelato executors, or chainlink registry to run performUpkeep
    @params checkerData, its a range of tokenIds that were encoded.
     */
    function checkUpkeep(bytes calldata checkerData)
        external
        view
        override
        returns (bool canExec, bytes memory execPayload)
    {
        (uint256 lowerBound, uint256 upperBound) = abi.decode(checkerData, (uint256, uint256));
        require(
            lowerBound > 0 && upperBound <= equipmentContract.totalSupply() && lowerBound <= upperBound,
            "Lower and Upper not correct"
        );

        uint256 counter = 0;

        for (uint256 i = 0; i < upperBound - lowerBound + 1; i++) {
            uint256 tokenId = lowerBound + i;

            if (!equipmentContract.isTokenExists(tokenId) || equipmentContract.getMetadataForToken(tokenId).isSet == true) {
                continue;
            }

            uint256 _generationId = getGenerationOfToken(tokenId);
            uint256 _seed = genSeed[_generationId];

            if (_seed == 0) {
                continue;
            }

            counter++;
            if(counter == 10){
                break;
            }
        }
       
        if (counter == 0) {
            return (false, "Meta set for range");
        }
      
        canExec = false;

        // to determine how many elements in an array need to update
        uint256[] memory tokenIds = new uint256[](counter);
        EquipmentMetadata[] memory metaDataArray = new EquipmentMetadata[](counter);

        uint256 indexToAdd = 0;
        for (uint256 i = 0; i < upperBound - lowerBound + 1; i++) {
            uint256 tokenId = lowerBound + i;

            uint256 _generationId = getGenerationOfToken(tokenId);
            uint256 _generationSeed = genSeed[_generationId];

            if (
                equipmentContract.isTokenExists(tokenId) &&
                _generationSeed != 0 &&
                equipmentContract.getMetadataForToken(tokenId).isSet == false
            ) {
                // do not access array index using tokenId as it is not be the correct index of the array
                canExec = true;
                tokenIds[indexToAdd] = tokenId;

                uint256 _seedForThisToken = uint256(
                    keccak256(abi.encode(_generationSeed, tokenId))
                );
                string memory equipmentName;
                EquipmentRarity rarity;
                EquipmentType typeOf = equipmentData.pluckType(_seedForThisToken);

                if (typeOf == EquipmentType.BODY) {
                    (equipmentName, rarity) = equipmentData.pluckBody(_seedForThisToken);
                } else if (typeOf == EquipmentType.CLAWS) {
                    (equipmentName, rarity) = equipmentData.pluckClaws(_seedForThisToken);
                } else if (typeOf == EquipmentType.LEGS) {
                    (equipmentName, rarity) = equipmentData.pluckLegs(_seedForThisToken);
                } else if (typeOf == EquipmentType.SHELL) {
                    (equipmentName, rarity) = equipmentData.pluckShell(_seedForThisToken);
                } else if (typeOf == EquipmentType.HABITAT) {
                    (equipmentName, rarity) = equipmentData.pluckHabitat(_seedForThisToken);
                } else if (typeOf == EquipmentType.HEADPIECES) {
                    (equipmentName, rarity) = equipmentData.pluckHeadpieces(_seedForThisToken);
                } else {
                    // return (false, abi.encodePacked("Invalid equipment type"));
                    return (false, "Invalid equipment type");
                }

                metaDataArray[indexToAdd] = EquipmentMetadata({
                    name: equipmentName,
                    equipmentRarity: rarity,
                    equipmentType: typeOf,
                    isSet: true
                });

                indexToAdd++;
            }
            if(indexToAdd == 10){
                break;
            }
        }
        
        bytes memory performData = abi.encode(tokenIds, metaDataArray);
     
        // execPayload = abi.encodeWithSelector(this.setMetaDataForRange.selector, performData); This payload is for gelato, as gelato executors need to know which function to be called
        return (canExec, performData);
    }


    /**
    @dev This function is called by either gelato or chainlink as part of automation chain
    The idea is to have the checker read all the high-gas calculation, and then pass the result of the calculation into another function to perform it
    We would have to validate the data again as well, before making any changes.
    * @params performData The data in bytes, this is the data we encoded from checker function above
     */
    function performUpkeep(bytes calldata performData) external {      
        require(_automationRegistry == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not approved to perform upkeep");
        // require(address(0xc1C6805B857Bef1f412519C4A842522431aFed39) == msg.sender, "Not approved to set metadata"); // this is for gelato

        (uint256[] memory tokenIds, EquipmentMetadata[] memory metaDataArray) = abi.decode(
            performData,
            (uint256[], EquipmentMetadata[])
        );

        if (tokenIds.length != metaDataArray.length) {
            revert("Invalid performData");
        }

        // important to always check that the data provided by the Automation Nodes is not corrupted.
        for (uint256 index = 0; index < tokenIds.length; index++) {
            uint256 tokenId = tokenIds[index];

            uint256 _generationId = getGenerationOfToken(tokenId);
            uint256 _generationSeed = genSeed[_generationId];

            if (_generationSeed == 0 || equipmentContract.getMetadataForToken(tokenId).isSet == true) {
                continue;
            }

            bytes memory _dataToSet = abi.encode(tokenId,  metaDataArray[index]);
            equipmentContract.setMetaDataForToken(_dataToSet);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(CantBeEvil, AccessControlEnumerable) returns (bool) {
        return CantBeEvil.supportsInterface(interfaceId) || super.supportsInterface(interfaceId);
    }

    function setEquipmentContract(address _equipmentContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        equipmentContract = IAnomuraEquipment(_equipmentContract);
    }

    /**
    @dev Automation registry is changed overtime, we need a way to set it and change to another 
     */
    function setAutomationRegistry(address automationRegistry_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _automationRegistry = automationRegistry_;
    }
}
