-- ============================================================================
-- InventorySystem.lua — 仓库系统
-- 物品实例化存储，分类管理，装备槽管理，词条加成汇总
-- ============================================================================

local GameConfig = require("config.GameConfig")
local ItemFactory = require("systems.ItemFactory")
local AffixSystem = require("systems.AffixSystem")

local InventorySystem = {}

-- 内部状态
local items_ = {}                                    -- { [uid] = itemInstance }
local NUM_EQUIP_SLOTS = 5                             -- 装备槽数量
local equipSlots_ = { nil, nil, nil, nil, nil }       -- 装备槽 { [1..5]=uid|nil }
local MAX_CAPACITY = 80                               -- 仓库容量上限

-- ============================================================================
-- 初始化 / 重置
-- ============================================================================

function InventorySystem.Init()
    items_ = {}
    equipSlots_ = {}
    for i = 1, NUM_EQUIP_SLOTS do equipSlots_[i] = nil end
    -- 确保铁剑存在
    if not InventorySystem.HasWeaponBase("iron_sword") then
        local sword = ItemFactory.CreateFixed("iron_sword", "weapon", 1, {})
        sword.source = "starter"
        items_[sword.uid] = sword
    end
    print("[InventorySystem] 初始化完成")
end

function InventorySystem.Reset()
    items_ = {}
    equipSlots_ = {}
    for i = 1, NUM_EQUIP_SLOTS do equipSlots_[i] = nil end
    -- 重新创建铁剑
    local sword = ItemFactory.CreateFixed("iron_sword", "weapon", 1, {})
    sword.source = "starter"
    items_[sword.uid] = sword
    print("[InventorySystem] 已重置")
end

-- ============================================================================
-- 物品管理
-- ============================================================================

--- 添加物品到仓库
---@param itemInstance table
---@return boolean success
function InventorySystem.AddItem(itemInstance)
    if not itemInstance or not itemInstance.uid then return false end

    -- 容量检查
    local count = 0
    for _ in pairs(items_) do count = count + 1 end
    if count >= MAX_CAPACITY then
        print("[InventorySystem] 仓库已满，无法添加: " .. (itemInstance.baseId or "?"))
        return false
    end

    items_[itemInstance.uid] = itemInstance
    print("[InventorySystem] 添加物品: " .. (itemInstance.baseId or "?")
        .. " [" .. (require("data.RarityData").GetRarityName(itemInstance.rarity)) .. "]")
    return true
end

--- 移除物品
---@param uid string
---@return table|nil removedItem
function InventorySystem.RemoveItem(uid)
    local item = items_[uid]
    if not item then return nil end

    -- 先卸下装备
    for i = 1, 2 do
        if equipSlots_[i] == uid then
            equipSlots_[i] = nil
        end
    end

    items_[uid] = nil
    return item
end

--- 分解物品，返回觉醒点数
---@param uid string
---@return number points 获得的觉醒点
function InventorySystem.DismantleItem(uid)
    local item = items_[uid]
    if not item then return 0 end
    if item.baseId == "iron_sword" then return 0 end

    local AwakeningSystem = require("systems.AwakeningSystem")
    local points = AwakeningSystem.CalcDismantlePoints(item)

    -- 移除物品（含卸下装备）
    InventorySystem.RemoveItem(uid)

    -- 增加觉醒点
    AwakeningSystem.AddPoints(points)

    print("[InventorySystem] 分解物品: " .. (item.baseId or "?") .. " 获得 " .. points .. " 觉醒点")
    return points
end

--- 获取物品
---@param uid string
---@return table|nil
function InventorySystem.GetItem(uid)
    return items_[uid]
end

--- 获取所有物品
---@return table { [uid] = itemInstance }
function InventorySystem.GetAllItems()
    return items_
end

--- 获取物品总数
---@return number
function InventorySystem.GetItemCount()
    local count = 0
    for _ in pairs(items_) do count = count + 1 end
    return count
end

--- 按分类获取物品（按品级降序排列）
---@param category string "weapon"|"equipment"|"item"
---@return table[] 物品实例数组
function InventorySystem.GetItemsByCategory(category)
    local result = {}
    for _, item in pairs(items_) do
        if item.category == category then
            table.insert(result, item)
        end
    end
    -- 按品级降序排列
    table.sort(result, function(a, b)
        if a.rarity ~= b.rarity then
            return a.rarity > b.rarity
        end
        return a.baseId < b.baseId
    end)
    return result
end

-- ============================================================================
-- 向后兼容桥接
-- ============================================================================

--- 检查是否拥有某个 baseId 的武器（兼容 GameManager.HasItem 语义）
---@param baseId string
---@return boolean
function InventorySystem.HasWeaponBase(baseId)
    for _, item in pairs(items_) do
        if item.baseId == baseId and item.category == "weapon" then
            return true
        end
    end
    return false
end

--- 检查是否拥有某个 baseId 的物品（任意分类）
---@param baseId string
---@return boolean
function InventorySystem.HasItemBase(baseId)
    for _, item in pairs(items_) do
        if item.baseId == baseId then
            return true
        end
    end
    return false
end

--- 获取某个 baseId 最高品级的武器实例
---@param baseId string
---@return table|nil
function InventorySystem.GetBestWeaponInstance(baseId)
    local best = nil
    for _, item in pairs(items_) do
        if item.baseId == baseId and item.category == "weapon" then
            if not best or item.rarity > best.rarity then
                best = item
            end
        end
    end
    return best
end

-- ============================================================================
-- 装备槽管理
-- ============================================================================

--- 装备到指定槽位（支持 weapon/equipment/item 所有类别）
---@param uid string 物品UID
---@param slot number 1~5
---@return boolean success
function InventorySystem.EquipToSlot(uid, slot)
    if slot < 1 or slot > NUM_EQUIP_SLOTS then return false end
    local item = items_[uid]
    if not item then return false end

    -- 如果该物品已在其他槽位，先卸下
    for i = 1, NUM_EQUIP_SLOTS do
        if equipSlots_[i] == uid then
            equipSlots_[i] = nil
        end
    end

    equipSlots_[slot] = uid
    print("[InventorySystem] 装备到槽位" .. slot .. ": " .. item.baseId .. " (" .. item.category .. ")")
    return true
end

--- 自动装备（空槽优先，否则替换槽1）
---@param uid string
---@return number slot 装备的槽位(0表示失败)
function InventorySystem.AutoEquip(uid)
    local item = items_[uid]
    if not item then return 0 end

    -- 找空槽
    for i = 1, NUM_EQUIP_SLOTS do
        if not equipSlots_[i] then
            equipSlots_[i] = uid
            print("[InventorySystem] 自动装备到槽位" .. i .. ": " .. item.baseId)
            return i
        end
    end

    -- 无空槽，替换槽1
    equipSlots_[1] = uid
    print("[InventorySystem] 替换装备槽1: " .. item.baseId)
    return 1
end

--- 卸下装备
---@param slot number 1~5
---@return string|nil uid
function InventorySystem.UnequipSlot(slot)
    if slot < 1 or slot > NUM_EQUIP_SLOTS then return nil end
    local uid = equipSlots_[slot]
    equipSlots_[slot] = nil
    return uid
end

--- 获取装备槽UID
---@param slot number
---@return string|nil
function InventorySystem.GetEquippedUID(slot)
    return equipSlots_[slot]
end

--- 获取装备槽物品实例
---@param slot number
---@return table|nil
function InventorySystem.GetEquippedItem(slot)
    local uid = equipSlots_[slot]
    if uid then return items_[uid] end
    return nil
end

--- 检查物品是否已装备
---@param uid string
---@return boolean
function InventorySystem.IsEquipped(uid)
    for i = 1, NUM_EQUIP_SLOTS do
        if equipSlots_[i] == uid then return true end
    end
    return false
end

--- 返回装备槽总数
---@return number
function InventorySystem.GetNumEquipSlots()
    return NUM_EQUIP_SLOTS
end

-- ============================================================================
-- 词条加成汇总
-- ============================================================================

--- 获取所有已装备物品的词条加成总和
---@param statName string 属性名
---@return number
function InventorySystem.GetTotalAffixBonus(statName)
    local total = 0
    for i = 1, NUM_EQUIP_SLOTS do
        local item = InventorySystem.GetEquippedItem(i)
        if item and item.affixes then
            for _, affix in ipairs(item.affixes) do
                if affix.stat == statName then
                    total = total + affix.value
                end
            end
        end
    end
    return total
end

-- ============================================================================
-- 存档
-- ============================================================================

---@return table
function InventorySystem.GetSaveData()
    -- 将 items_ 转为数组以便 JSON 序列化
    local itemList = {}
    for _, item in pairs(items_) do
        table.insert(itemList, {
            uid      = item.uid,
            baseId   = item.baseId,
            category = item.category,
            rarity   = item.rarity,
            affixes  = item.affixes,
            maxSlots = item.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS,
            source   = item.source,
        })
    end
    local slots = {}
    for i = 1, NUM_EQUIP_SLOTS do slots[i] = equipSlots_[i] end
    return {
        items      = itemList,
        equipSlots = slots,
    }
end

---@param data table
function InventorySystem.LoadSaveData(data)
    items_ = {}
    equipSlots_ = { nil, nil }

    if not data then return end

    -- 加载物品列表
    if data.items then
        local maxUid = nil
        for _, itemData in ipairs(data.items) do
            local item = {
                uid      = itemData.uid,
                baseId   = itemData.baseId,
                category = itemData.category,
                rarity   = itemData.rarity or 1,
                affixes  = itemData.affixes or {},
                maxSlots = itemData.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS,
                source   = itemData.source or "fixed",
            }
            -- 迁移旧格式词条到新格式
            AffixSystem.MigrateItemAffixes(item)
            items_[item.uid] = item
            -- 追踪最大UID
            if not maxUid or item.uid > maxUid then
                maxUid = item.uid
            end
        end
        -- 同步计数器防止冲突
        ItemFactory.SyncCounter(maxUid)
    end

    -- 加载装备槽（兼容旧存档2槽 + 新存档5槽）
    if data.equipSlots then
        for i = 1, NUM_EQUIP_SLOTS do
            equipSlots_[i] = data.equipSlots[i]  -- 旧存档只有[1][2]，其余自动为nil
        end
    end

    -- 确保铁剑存在
    if not InventorySystem.HasWeaponBase("iron_sword") then
        local sword = ItemFactory.CreateFixed("iron_sword", "weapon", 1, {})
        sword.source = "starter"
        items_[sword.uid] = sword
    end

    print("[InventorySystem] 加载存档: " .. InventorySystem.GetItemCount() .. " 个物品")
end

--- 从旧格式迁移加载
---@param items table[] 物品实例数组
---@param eqSlots table 装备槽
function InventorySystem.LoadMigrated(items, eqSlots)
    items_ = {}
    equipSlots_ = {}
    for i = 1, NUM_EQUIP_SLOTS do equipSlots_[i] = nil end

    for _, item in ipairs(items) do
        items_[item.uid] = item
    end

    if eqSlots then
        for i = 1, NUM_EQUIP_SLOTS do
            equipSlots_[i] = eqSlots[i]
        end
    end

    -- 确保铁剑
    if not InventorySystem.HasWeaponBase("iron_sword") then
        local sword = ItemFactory.CreateFixed("iron_sword", "weapon", 1, {})
        sword.source = "starter"
        items_[sword.uid] = sword
    end

    print("[InventorySystem] 迁移加载: " .. InventorySystem.GetItemCount() .. " 个物品")
end

return InventorySystem
