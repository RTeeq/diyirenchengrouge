-- ============================================================================
-- AffixSystem.lua — 词条系统（掷骰 / 水晶扩槽 / NPC刷新）
-- ============================================================================

local AffixDatabase = require("data.AffixDatabase")

local AffixSystem = {}

-- ============================================================================
-- 常量
-- ============================================================================

--- 默认最大词条槽数
AffixSystem.DEFAULT_MAX_SLOTS = 3

--- 词条槽绝对上限（水晶扩展后的最大值）
AffixSystem.ABSOLUTE_MAX_SLOTS = 9

--- 水晶定义（6级，与词条品质对应）
AffixSystem.CrystalTiers = {
    [1] = { id = "crystal_t1", name = "初级水晶", tier = 1, price = 100,  icon = "💎" },
    [2] = { id = "crystal_t2", name = "中级水晶", tier = 2, price = 300,  icon = "💎" },
    [3] = { id = "crystal_t3", name = "高级水晶", tier = 3, price = 800,  icon = "💎" },
    [4] = { id = "crystal_t4", name = "顶级水晶", tier = 4, price = 2000, icon = "💎" },
    [5] = { id = "crystal_t5", name = "史诗水晶", tier = 5, price = 5000, icon = "💎" },
    [6] = { id = "crystal_t6", name = "至臻水晶", tier = 6, price = 15000,icon = "💎" },
}

--- NPC 刷新词条价格（按当前词条品质tier收费）
AffixSystem.RefreshPrices = {
    [1] = 50,    -- 普通
    [2] = 150,   -- 中级
    [3] = 400,   -- 高级
    [4] = 1000,  -- 顶级
    [5] = 3000,  -- 史诗
    [6] = 8000,  -- 至臻
}

-- ============================================================================
-- 品质掷骰
-- ============================================================================

--- 按权重随机品质等级
---@param minTier number|nil 最低品质保底（可选）
---@return number tier 1~6
function AffixSystem.RollQualityTier(minTier)
    local tiers = AffixDatabase.QualityTiers
    local totalWeight = 0
    for i = 1, 6 do
        totalWeight = totalWeight + tiers[i].weight
    end

    local roll = math.random() * totalWeight
    local cumulative = 0
    local result = 1
    for i = 1, 6 do
        cumulative = cumulative + tiers[i].weight
        if roll <= cumulative then
            result = i
            break
        end
    end

    -- 保底
    if minTier and result < minTier then
        result = minTier
    end

    return result
end

-- ============================================================================
-- 词条掷骰
-- ============================================================================

--- 在指定品质中随机选取一个词条
---@param tier number 品质等级 1~6
---@param excludeIds table|nil 已有词条模板ID集合 {[templateId]=true}
---@return table|nil affix 词条实例（深拷贝）
function AffixSystem.RollAffixAtTier(tier, excludeIds)
    local pool = AffixDatabase.ByTier[tier]
    if not pool or #pool == 0 then return nil end

    -- 过滤已有的模板（同模板不同品质也排除）
    local candidates = {}
    for _, af in ipairs(pool) do
        if not excludeIds or not excludeIds[af.templateId] then
            table.insert(candidates, af)
        end
    end

    if #candidates == 0 then return nil end

    local pick = candidates[math.random(1, #candidates)]
    -- 深拷贝
    return {
        id         = pick.id,
        templateId = pick.templateId,
        name       = pick.name,
        baseName   = pick.baseName,
        stat       = pick.stat,
        statName   = pick.statName,
        unit       = pick.unit,
        category   = pick.category,
        value      = pick.value,
        tier       = pick.tier,
        tierName   = pick.tierName,
    }
end

--- 随机掷骰一个词条（先掷品质再掷具体词条）
---@param minTier number|nil 最低品质
---@param excludeIds table|nil 排除的模板ID
---@return table|nil affix
function AffixSystem.RollAffix(minTier, excludeIds)
    local tier = AffixSystem.RollQualityTier(minTier)
    return AffixSystem.RollAffixAtTier(tier, excludeIds)
end

--- 为物品掉落批量掷骰词条
---@param count number 词条数量
---@param minTier number|nil 最低品质
---@return table[] affixes
function AffixSystem.RollAffixes(count, minTier)
    if count <= 0 then return {} end

    local affixes = {}
    local usedTemplates = {}

    for _ = 1, count do
        local affix = AffixSystem.RollAffix(minTier, usedTemplates)
        if affix then
            table.insert(affixes, affix)
            usedTemplates[affix.templateId] = true
        end
    end

    return affixes
end

-- ============================================================================
-- 物品词条槽管理
-- ============================================================================

--- 获取物品的最大词条槽数
---@param item table 物品实例
---@return number
function AffixSystem.GetMaxSlots(item)
    return item.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS
end

--- 获取物品当前词条数
---@param item table
---@return number
function AffixSystem.GetCurrentAffixCount(item)
    if not item.affixes then return 0 end
    return #item.affixes
end

--- 检查是否可以使用水晶扩展词条槽
---@param item table
---@param crystalTier number 水晶等级 1~6
---@return boolean canApply
---@return string|nil reason 失败原因
function AffixSystem.CanApplyCrystal(item, crystalTier)
    if not item then return false, "物品不存在" end
    if item.baseId == "iron_sword" then return false, "铁剑无法强化" end

    local maxSlots = AffixSystem.GetMaxSlots(item)
    if maxSlots >= AffixSystem.ABSOLUTE_MAX_SLOTS then
        return false, "词条槽已达上限(" .. AffixSystem.ABSOLUTE_MAX_SLOTS .. ")"
    end

    if crystalTier < 1 or crystalTier > 6 then
        return false, "无效的水晶等级"
    end

    return true, nil
end

--- 使用水晶：扩展1个词条槽 + 附带对应品质词条
---@param item table 物品实例（就地修改）
---@param crystalTier number 水晶等级 1~6
---@return boolean success
---@return string message
function AffixSystem.ApplyCrystal(item, crystalTier)
    local canApply, reason = AffixSystem.CanApplyCrystal(item, crystalTier)
    if not canApply then
        return false, reason
    end

    -- 扩展槽位
    item.maxSlots = (item.maxSlots or AffixSystem.DEFAULT_MAX_SLOTS) + 1

    -- 收集已有词条模板
    local usedTemplates = {}
    if item.affixes then
        for _, af in ipairs(item.affixes) do
            if af.templateId then
                usedTemplates[af.templateId] = true
            end
        end
    else
        item.affixes = {}
    end

    -- 附带对应品质词条
    local newAffix = AffixSystem.RollAffixAtTier(crystalTier, usedTemplates)
    if newAffix then
        table.insert(item.affixes, newAffix)
        local crystalName = AffixSystem.CrystalTiers[crystalTier].name
        local msg = crystalName .. " 使用成功！\n"
            .. "词条槽 +" .. 1 .. " → " .. item.maxSlots .. "\n"
            .. "获得词条: " .. AffixDatabase.FormatAffixFull(newAffix)
        print("[AffixSystem] " .. msg)
        return true, msg
    else
        local crystalName = AffixSystem.CrystalTiers[crystalTier].name
        local msg = crystalName .. " 使用成功！词条槽 +1 → " .. item.maxSlots
            .. "（无可用词条模板）"
        print("[AffixSystem] " .. msg)
        return true, msg
    end
end

-- ============================================================================
-- NPC 刷新词条
-- ============================================================================

--- 检查是否可以刷新指定槽位的词条
---@param item table
---@param slotIndex number 词条槽索引（从1开始）
---@return boolean canRefresh
---@return string|nil reason
function AffixSystem.CanRefreshAffix(item, slotIndex)
    if not item then return false, "物品不存在" end
    if item.baseId == "iron_sword" then return false, "铁剑无法锻造" end
    if not item.affixes or #item.affixes == 0 then
        return false, "该物品没有词条"
    end
    if slotIndex < 1 or slotIndex > #item.affixes then
        return false, "无效的词条槽位"
    end
    return true, nil
end

--- 获取刷新词条的价格
---@param item table
---@param slotIndex number
---@return number price
function AffixSystem.GetRefreshPrice(item, slotIndex)
    if not item or not item.affixes then return 0 end
    local affix = item.affixes[slotIndex]
    if not affix then return 0 end
    local tier = affix.tier or 1
    return AffixSystem.RefreshPrices[tier] or 50
end

--- 刷新指定槽位的词条（重新掷骰同品质）
---@param item table
---@param slotIndex number
---@return boolean success
---@return string message
function AffixSystem.RefreshAffix(item, slotIndex)
    local canRefresh, reason = AffixSystem.CanRefreshAffix(item, slotIndex)
    if not canRefresh then
        return false, reason
    end

    local oldAffix = item.affixes[slotIndex]
    local tier = oldAffix.tier or 1

    -- 收集其他词条的模板ID（排除当前要刷新的）
    local usedTemplates = {}
    for i, af in ipairs(item.affixes) do
        if i ~= slotIndex and af.templateId then
            usedTemplates[af.templateId] = true
        end
    end

    -- 同品质重新掷骰
    local newAffix = AffixSystem.RollAffixAtTier(tier, usedTemplates)
    if not newAffix then
        return false, "没有可用的替换词条"
    end

    item.affixes[slotIndex] = newAffix

    local msg = "词条刷新成功！\n"
        .. "旧: " .. AffixDatabase.FormatAffixFull(oldAffix) .. "\n"
        .. "新: " .. AffixDatabase.FormatAffixFull(newAffix)
    print("[AffixSystem] " .. msg)
    return true, msg
end

-- ============================================================================
-- 兼容桥接：从旧格式词条转换
-- ============================================================================

--- 将旧格式词条 {stat, name, value, unit} 转为新格式
---@param oldAffix table
---@return table newAffix
function AffixSystem.ConvertOldAffix(oldAffix)
    if oldAffix.templateId then
        -- 已经是新格式
        return oldAffix
    end

    -- 查找最匹配的词条模板
    local stat = oldAffix.stat
    local value = oldAffix.value or 0

    -- 找到最接近的品质
    local bestMatch = nil
    local bestDiff = 9999

    for _, af in ipairs(AffixDatabase.All) do
        if af.stat == stat then
            local diff = math.abs(af.value - value)
            if diff < bestDiff then
                bestDiff = diff
                bestMatch = af
            end
        end
    end

    if bestMatch then
        return {
            id         = bestMatch.id,
            templateId = bestMatch.templateId,
            name       = bestMatch.name,
            baseName   = bestMatch.baseName,
            stat       = bestMatch.stat,
            statName   = bestMatch.statName,
            unit       = bestMatch.unit,
            category   = bestMatch.category,
            value      = bestMatch.value,
            tier       = bestMatch.tier,
            tierName   = bestMatch.tierName,
        }
    end

    -- 无匹配，保持旧格式但补充必要字段
    return {
        id         = "legacy_" .. (stat or "unknown"),
        templateId = "legacy",
        name       = oldAffix.name or stat,
        baseName   = oldAffix.name or stat,
        stat       = stat,
        statName   = oldAffix.name or stat,
        unit       = oldAffix.unit or "",
        category   = "special",
        value      = value,
        tier       = 1,
        tierName   = "普通",
    }
end

--- 迁移物品的所有旧格式词条
---@param item table
function AffixSystem.MigrateItemAffixes(item)
    if not item or not item.affixes then return end
    for i, af in ipairs(item.affixes) do
        item.affixes[i] = AffixSystem.ConvertOldAffix(af)
    end
end

-- ============================================================================
-- 格式化辅助（转发到 AffixDatabase）
-- ============================================================================

AffixSystem.FormatAffix     = AffixDatabase.FormatAffix
AffixSystem.FormatAffixFull = AffixDatabase.FormatAffixFull
AffixSystem.GetQualityColor = AffixDatabase.GetQualityColor
AffixSystem.GetQualityName  = AffixDatabase.GetQualityName

print("[AffixSystem] 初始化完成")

return AffixSystem
