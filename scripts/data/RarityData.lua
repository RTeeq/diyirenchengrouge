-- ============================================================================
-- RarityData.lua — 品级系统（稀有度 + 词条池 + 掷骰逻辑）
-- ============================================================================

local DifficultySystem = require("systems.DifficultySystem")

local RarityData = {}

-- ============================================================================
-- 品级定义
-- ============================================================================

---@class RarityTier
---@field name string
---@field color table {r,g,b,a}
---@field statMult number 基础属性倍率
---@field maxAffixes number 最大词条数
---@field weight number 基础掉落权重

RarityData.Tiers = {
    [1] = { name = "普通", color = {180, 180, 180, 255}, statMult = 1.00, maxAffixes = 0, weight = 60 },
    [2] = { name = "优秀", color = {100, 220, 100, 255}, statMult = 1.15, maxAffixes = 1, weight = 25 },
    [3] = { name = "稀有", color = { 80, 140, 255, 255}, statMult = 1.30, maxAffixes = 2, weight = 10 },
    [4] = { name = "史诗", color = {180,  80, 255, 255}, statMult = 1.50, maxAffixes = 2, weight =  4 },
    [5] = { name = "传说", color = {255, 170,  30, 255}, statMult = 1.80, maxAffixes = 3, weight =  1 },
}

-- ============================================================================
-- 词条池
-- ============================================================================

---@class AffixDef
---@field stat string
---@field name string
---@field min number
---@field max number
---@field unit string

RarityData.AffixPool = {
    { stat = "damagePct",   name = "伤害",     min = 3,  max = 15, unit = "%" },
    { stat = "maxHP",       name = "生命",     min = 5,  max = 30, unit = ""  },
    { stat = "cooldownPct", name = "冷却缩减", min = 3,  max = 10, unit = "%" },
    { stat = "atkSpdPct",   name = "攻速",     min = 3,  max = 12, unit = "%" },
    { stat = "moveSpdPct",  name = "移速",     min = 2,  max = 8,  unit = "%" },
    { stat = "rangePct",    name = "范围",     min = 3,  max = 10, unit = "%" },
    { stat = "critPct",     name = "暴击",     min = 2,  max = 8,  unit = "%" },
}

-- ============================================================================
-- 品级查询
-- ============================================================================

---@param rarity number 1~5
---@return RarityTier
function RarityData.GetTier(rarity)
    return RarityData.Tiers[rarity] or RarityData.Tiers[1]
end

---@param rarity number
---@return string
function RarityData.GetRarityName(rarity)
    local tier = RarityData.GetTier(rarity)
    return tier.name
end

---@param rarity number
---@return table {r,g,b,a}
function RarityData.GetRarityColor(rarity)
    local tier = RarityData.GetTier(rarity)
    return tier.color
end

-- ============================================================================
-- 掷骰逻辑
-- ============================================================================

--- 根据敌人等级和类型掷骰品级
---@param enemyLevel number
---@param isBoss boolean
---@param isElite boolean
---@return number rarity 1~5
function RarityData.RollRarity(enemyLevel, isBoss, isElite)
    local lvl = enemyLevel or 1

    -- 基础权重复制
    local weights = {}
    for i = 1, 5 do
        weights[i] = RarityData.Tiers[i].weight
    end

    -- 等级提升高品级权重
    weights[2] = weights[2] + lvl * 1.0
    weights[3] = weights[3] + lvl * 0.5
    weights[4] = weights[4] + lvl * 0.2
    weights[5] = weights[5] + lvl * 0.05

    -- 难度加成（困难/炼狱大幅提升稀有掉落）
    local bonus = DifficultySystem.GetDropRarityBonus()
    if bonus > 0 then
        weights[3] = weights[3] + bonus
        weights[4] = weights[4] + bonus * 0.6
        weights[5] = weights[5] + bonus * 0.3
    end

    -- 计算总权重并掷骰
    local totalWeight = 0
    for i = 1, 5 do totalWeight = totalWeight + weights[i] end

    local roll = math.random() * totalWeight
    local cumulative = 0
    local rarity = 1
    for i = 1, 5 do
        cumulative = cumulative + weights[i]
        if roll <= cumulative then
            rarity = i
            break
        end
    end

    -- Boss 保底稀有(3)，精英保底优秀(2)
    if isBoss and rarity < 3 then
        rarity = 3
    elseif isElite and rarity < 2 then
        rarity = 2
    end

    return rarity
end

--- 根据品级随机生成词条（委托给 AffixSystem）
---@param rarity number 1~5
---@return table[] affixes
function RarityData.RollAffixes(rarity)
    local AffixSystem = require("systems.AffixSystem")
    local tier = RarityData.GetTier(rarity)
    local count = math.min(rarity - 1, tier.maxAffixes)
    if count <= 0 then return {} end

    -- 品级越高，词条品质保底越高
    local minAffixTier = nil
    if rarity >= 5 then minAffixTier = 2   -- 传说：至少中级词条
    elseif rarity >= 4 then minAffixTier = 1 -- 史诗：至少普通
    end

    return AffixSystem.RollAffixes(count, minAffixTier)
end

--- 格式化词条为显示文本（兼容新旧格式）
---@param affix table
---@return string
function RarityData.FormatAffix(affix)
    -- 新格式（有 templateId）使用 AffixDatabase
    if affix.templateId then
        local AffixDatabase = require("data.AffixDatabase")
        return AffixDatabase.FormatAffix(affix)
    end
    -- 旧格式兼容
    if affix.unit == "%" then
        return "+" .. affix.value .. "% " .. (affix.name or affix.statName or "")
    else
        return "+" .. affix.value .. " " .. (affix.name or affix.statName or "")
    end
end

return RarityData
