-- ============================================================================
-- GameManager.lua — 游戏状态机
-- 管理游戏状态切换、全局数据
-- ============================================================================

local GameConfig = require("config.GameConfig")

local GameManager = {}
GameManager.__index = GameManager

local States = GameConfig.States
local currentState_ = States.PLAYING
local previousState_ = nil

-- InventorySystem 注入（延迟绑定，避免循环依赖）
local InventorySystem_ = nil

--- 注入 InventorySystem 引用
---@param invSys table
function GameManager.SetInventorySystem(invSys)
    InventorySystem_ = invSys
end

-- 玩家数据
local playerData_ = {
    inventory = { iron_sword = true },  -- 已收集物品 { [itemId] = true }，铁剑出生自带
    questProgress = 0,     -- 当前任务进度
    visitedAreas = {},     -- 已访问区域
    talkedNPCs = {},       -- 已对话 NPC
    equipment = { nil, nil, nil, nil, nil },  -- 装备槽(最多5件)
    gold = 0,              -- 金币
    crystal = 0,           -- 水晶
}

-- 状态变化回调
local stateCallbacks_ = {}

-- ============================================================================
-- 状态管理
-- ============================================================================

---@return string 当前状态
function GameManager.GetState()
    return currentState_
end

---@param state string 新状态
function GameManager.SetState(state)
    if currentState_ == state then return end

    previousState_ = currentState_
    currentState_ = state

    print("[GameManager] 状态切换: " .. (previousState_ or "nil") .. " -> " .. state)

    -- 触发回调
    if stateCallbacks_[state] then
        for _, cb in ipairs(stateCallbacks_[state]) do
            cb(state, previousState_)
        end
    end
end

---@return string|nil 前一个状态
function GameManager.GetPreviousState()
    return previousState_
end

--- 恢复到前一个状态
function GameManager.RestorePreviousState()
    if previousState_ then
        GameManager.SetState(previousState_)
    end
end

---@param state string
---@param callback function(newState, oldState)
function GameManager.OnStateChange(state, callback)
    if not stateCallbacks_[state] then
        stateCallbacks_[state] = {}
    end
    table.insert(stateCallbacks_[state], callback)
end

--- 检查是否在游戏中（非UI覆盖状态）
---@return boolean
function GameManager.IsPlaying()
    return currentState_ == States.PLAYING
end

--- 检查是否在UI覆盖状态
---@return boolean
function GameManager.IsUIActive()
    return currentState_ ~= States.PLAYING
        and currentState_ ~= States.MAIN_MENU
end

-- ============================================================================
-- 物品管理
-- ============================================================================

---@param itemId string
function GameManager.AddItem(itemId)
    if InventorySystem_ then
        -- 新系统：创建普通品级物品实例
        local ItemFactory = require("systems.ItemFactory")
        local cat = "item"
        if GameConfig.Weapons and GameConfig.Weapons[itemId] then cat = "weapon"
        elseif GameConfig.Equipment and GameConfig.Equipment[itemId] then cat = "equipment" end
        local inst = ItemFactory.CreateFixed(itemId, cat, 1, {})
        inst.source = "shop"
        InventorySystem_.AddItem(inst)
    else
        playerData_.inventory[itemId] = true
    end
    print("[GameManager] 获得物品: " .. itemId)
end

---@param itemId string
---@return boolean
function GameManager.HasItem(itemId)
    if InventorySystem_ then
        return InventorySystem_.HasItemBase(itemId)
    end
    return playerData_.inventory[itemId] == true
end

---@return table<string, boolean>
function GameManager.GetInventory()
    return playerData_.inventory
end

---@return number
function GameManager.GetItemCount()
    if InventorySystem_ then
        return InventorySystem_.GetItemCount()
    end
    local count = 0
    for _ in pairs(playerData_.inventory) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- 任务进度
-- ============================================================================

---@param progress number
function GameManager.SetQuestProgress(progress)
    playerData_.questProgress = progress
    print("[GameManager] 任务进度: " .. progress)
end

---@return number
function GameManager.GetQuestProgress()
    return playerData_.questProgress
end

-- ============================================================================
-- NPC 对话记录
-- ============================================================================

---@param npcId string
function GameManager.MarkNPCTalked(npcId)
    playerData_.talkedNPCs[npcId] = true
end

---@param npcId string
---@return boolean
function GameManager.HasTalkedNPC(npcId)
    return playerData_.talkedNPCs[npcId] == true
end

-- ============================================================================
-- 装备管理
-- ============================================================================

---@param slot number 1~5
---@param equipId string|nil
function GameManager.SetEquipment(slot, equipId)
    if slot >= 1 and slot <= 5 then
        playerData_.equipment[slot] = equipId
    end
end

---@return table { [1..5]=id|nil }
function GameManager.GetEquipment()
    return playerData_.equipment
end

-- ============================================================================
-- 货币管理
-- ============================================================================

---@param amount number
function GameManager.AddGold(amount)
    playerData_.gold = (playerData_.gold or 0) + amount
end

---@return number
function GameManager.GetGold()
    return playerData_.gold or 0
end

---@param amount number
function GameManager.AddCrystal(amount)
    playerData_.crystal = (playerData_.crystal or 0) + amount
end

---@return number
function GameManager.GetCrystal()
    return playerData_.crystal or 0
end

---@param amount number
---@return boolean
function GameManager.SpendGold(amount)
    if (playerData_.gold or 0) < amount then return false end
    playerData_.gold = playerData_.gold - amount
    return true
end

---@param amount number
---@return boolean
function GameManager.CanAfford(amount)
    return (playerData_.gold or 0) >= amount
end

-- ============================================================================
-- 快照系统（安全区结算时保存，死亡时恢复）
-- 确保金币/水晶/背包/装备/觉醒点只在回安全区后才永久保留
-- ============================================================================

local snapshot_ = nil

--- 保存当前资源快照（安全区结算后、新建/加载存档后调用）
function GameManager.SaveSnapshot()
    snapshot_ = {
        gold = playerData_.gold or 0,
        crystal = playerData_.crystal or 0,
    }
    if InventorySystem_ and InventorySystem_.GetSaveData then
        snapshot_.inventoryV2 = InventorySystem_.GetSaveData()
    end
    local okAwk, AwkSys = pcall(require, "systems.AwakeningSystem")
    if okAwk and AwkSys and AwkSys.GetSaveData then
        snapshot_.awakening = AwkSys.GetSaveData()
    end
    print("[GameManager] 资源快照已保存 (金币:" .. snapshot_.gold .. " 水晶:" .. snapshot_.crystal .. ")")
end

--- 恢复到上次快照（死亡重开时调用，只丢失本次出征的收益）
---@return boolean 是否成功恢复
function GameManager.RestoreSnapshot()
    if not snapshot_ then
        print("[GameManager] 无快照可恢复")
        return false
    end
    playerData_.gold = snapshot_.gold
    playerData_.crystal = snapshot_.crystal
    if snapshot_.inventoryV2 and InventorySystem_ then
        InventorySystem_.LoadSaveData(snapshot_.inventoryV2)
    end
    if snapshot_.awakening then
        local okAwk, AwkSys = pcall(require, "systems.AwakeningSystem")
        if okAwk and AwkSys and AwkSys.LoadSaveData then
            AwkSys.LoadSaveData(snapshot_.awakening)
        end
    end
    print("[GameManager] 资源快照已恢复 (金币:" .. snapshot_.gold .. " 水晶:" .. snapshot_.crystal .. ")")
    return true
end

--- 检查是否有快照
---@return boolean
function GameManager.HasSnapshot()
    return snapshot_ ~= nil
end

-- ============================================================================
-- 存档数据（供 SaveSystem 使用）
-- ============================================================================

---@return table
function GameManager.GetSaveData()
    local data = {
        questProgress = playerData_.questProgress,
        visitedAreas = playerData_.visitedAreas,
        talkedNPCs = playerData_.talkedNPCs,
        gold = playerData_.gold or 0,
        crystal = playerData_.crystal or 0,
    }
    if InventorySystem_ then
        data.inventoryV2 = InventorySystem_.GetSaveData()
    else
        data.inventory = playerData_.inventory
        data.equipment = playerData_.equipment
    end
    -- 觉醒系统存档
    local okAwk, AwkSys = pcall(require, "systems.AwakeningSystem")
    if okAwk and AwkSys and AwkSys.GetSaveData then
        data.awakening = AwkSys.GetSaveData()
    end
    -- 难度系统存档
    local okDiff, DiffSys = pcall(require, "systems.DifficultySystem")
    if okDiff and DiffSys and DiffSys.GetSaveData then
        data.difficulty = DiffSys.GetSaveData()
    end
    return data
end

---@param data table
function GameManager.LoadSaveData(data)
    if data.questProgress then playerData_.questProgress = data.questProgress end
    if data.visitedAreas then playerData_.visitedAreas = data.visitedAreas end
    if data.talkedNPCs then playerData_.talkedNPCs = data.talkedNPCs end
    playerData_.gold = data.gold or 0
    playerData_.crystal = data.crystal or 0

    -- 新存档格式
    if data.inventoryV2 and InventorySystem_ then
        InventorySystem_.LoadSaveData(data.inventoryV2)
    elseif data.inventory then
        -- 旧存档格式：迁移
        if InventorySystem_ then
            local ItemFactory = require("systems.ItemFactory")
            local items, equipSlots = ItemFactory.MigrateOldInventory(
                data.inventory, data.equipment or { nil, nil, nil, nil, nil })
            InventorySystem_.LoadMigrated(items, equipSlots)
        else
            playerData_.inventory = data.inventory
            playerData_.equipment = data.equipment or { nil, nil, nil, nil, nil }
        end
    end

    -- 同步装备到旧字段（兼容 EquipmentSystem）
    if InventorySystem_ then
        for i = 1, 5 do
            local item = InventorySystem_.GetEquippedItem(i)
            playerData_.equipment[i] = item and item.baseId or nil
        end
    end

    -- 觉醒系统加载
    if data.awakening then
        local okAwk, AwkSys = pcall(require, "systems.AwakeningSystem")
        if okAwk and AwkSys and AwkSys.LoadSaveData then
            AwkSys.LoadSaveData(data.awakening)
        end
    end

    -- 难度系统加载
    if data.difficulty then
        local okDiff, DiffSys = pcall(require, "systems.DifficultySystem")
        if okDiff and DiffSys and DiffSys.LoadSaveData then
            DiffSys.LoadSaveData(data.difficulty)
        end
    end

    print("[GameManager] 存档数据已加载")
end

--- 重置所有数据（新游戏）
function GameManager.Reset()
    playerData_ = {
        inventory = { iron_sword = true },  -- 铁剑出生自带
        questProgress = 0,
        visitedAreas = {},
        talkedNPCs = {},
        equipment = { nil, nil, nil, nil, nil },
        gold = 0,
        crystal = 0,
    }
    currentState_ = States.PLAYING
    previousState_ = nil
    print("[GameManager] 游戏数据已重置")
end

return GameManager
