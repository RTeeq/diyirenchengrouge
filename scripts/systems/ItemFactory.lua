-- ============================================================================
-- ItemFactory.lua — 物品实例工厂
-- 生成带唯一ID、品级、词条的物品实例
-- ============================================================================

local GameConfig = require("config.GameConfig")
local RarityData = require("data.RarityData")
local AffixSystem = require("systems.AffixSystem")

local ItemFactory = {}

-- UID 生成器
local uidCounter_ = 0
local sessionId_ = tostring(os.time())

local function generateUID(prefix)
    uidCounter_ = uidCounter_ + 1
    return prefix .. "_" .. sessionId_ .. "_" .. string.format("%04d", uidCounter_)
end

-- ============================================================================
-- 分类判定辅助
-- ============================================================================

--- 判断 baseId 属于哪个分类
---@param baseId string
---@return string category "weapon"|"equipment"|"item"
local function detectCategory(baseId)
    if GameConfig.Weapons and GameConfig.Weapons[baseId] then
        return "weapon"
    elseif GameConfig.Equipment and GameConfig.Equipment[baseId] then
        return "equipment"
    else
        return "item"
    end
end

local CATEGORY_PREFIX = {
    weapon    = "wpn",
    equipment = "eqp",
    item      = "itm",
}

-- ============================================================================
-- 物品创建 API
-- ============================================================================

--- 从掉落创建物品（随机品级 + 随机词条）
---@param baseId string 基础物品ID
---@param category string "weapon"|"equipment"|"item"
---@param enemyLevel number 敌人等级
---@param enemyType string 敌人类型
---@param minRarity number|nil 最低品级保底
---@return table itemInstance
function ItemFactory.CreateFromDrop(baseId, category, enemyLevel, enemyType, minRarity)
    local isBoss = (enemyType == "boss" or enemyType == "levelBoss"
                    or enemyType == "dragonBoss" or enemyType == "ultimateBoss")
    local isElite = string.sub(enemyType or "", 1, 5) == "elite"

    local rarity = RarityData.RollRarity(enemyLevel, isBoss, isElite)
    -- 保底品级
    if minRarity and rarity < minRarity then
        rarity = minRarity
    end

    local affixes = RarityData.RollAffixes(rarity)
    local cat = category or detectCategory(baseId)
    local prefix = CATEGORY_PREFIX[cat] or "itm"

    return {
        uid      = generateUID(prefix),
        baseId   = baseId,
        category = cat,
        rarity   = rarity,
        affixes  = affixes,
        maxSlots = AffixSystem.DEFAULT_MAX_SLOTS,
        source   = "drop",
    }
end

--- 创建固定品级物品（商店购买、初始道具等）
---@param baseId string
---@param category string|nil 可选，自动检测
---@param rarity number 品级 1~5
---@param affixes table|nil 词条列表
---@return table itemInstance
function ItemFactory.CreateFixed(baseId, category, rarity, affixes)
    local cat = category or detectCategory(baseId)
    local prefix = CATEGORY_PREFIX[cat] or "itm"

    return {
        uid      = generateUID(prefix),
        baseId   = baseId,
        category = cat,
        rarity   = rarity or 1,
        affixes  = affixes or {},
        maxSlots = AffixSystem.DEFAULT_MAX_SLOTS,
        source   = "fixed",
    }
end

--- 迁移旧版布尔表存档到物品实例列表
---@param oldInv table { [itemId] = true }
---@param oldEquip table { [1]=id|nil, [2]=id|nil }
---@return table[] items 物品实例数组
---@return table equipSlots { [1]=uid|nil, [2]=uid|nil }
function ItemFactory.MigrateOldInventory(oldInv, oldEquip)
    local items = {}
    local equipSlots = { nil, nil }

    -- 迁移背包物品
    if oldInv then
        for itemId, val in pairs(oldInv) do
            if val == true then
                local cat = detectCategory(itemId)
                local inst = ItemFactory.CreateFixed(itemId, cat, 1, {})
                inst.source = "starter"
                table.insert(items, inst)
            end
        end
    end

    -- 迁移已装备物品（Boss装备升为传说品级）
    if oldEquip then
        for i = 1, 2 do
            if oldEquip[i] then
                local inst = ItemFactory.CreateFixed(oldEquip[i], "equipment", 5, {})
                inst.source = "boss"
                table.insert(items, inst)
                equipSlots[i] = inst.uid
            end
        end
    end

    print("[ItemFactory] 迁移旧存档: " .. #items .. " 个物品")
    return items, equipSlots
end

--- 获取物品的有效属性（基础属性 × 品级倍率）
---@param itemInstance table
---@return number statMult 品级属性倍率
function ItemFactory.GetStatMultiplier(itemInstance)
    local tier = RarityData.GetTier(itemInstance.rarity or 1)
    return tier.statMult
end

--- 恢复 UID 计数器（加载存档后防止冲突）
---@param maxUid string|nil 存档中最大的UID
function ItemFactory.SyncCounter(maxUid)
    if not maxUid then return end
    -- 从 UID 中提取计数器部分
    local numStr = string.match(maxUid, "_(%d+)$")
    if numStr then
        local num = tonumber(numStr) or 0
        if num >= uidCounter_ then
            uidCounter_ = num + 1
        end
    end
    -- 更新 sessionId 以避免冲突
    sessionId_ = tostring(os.time())
end

return ItemFactory
