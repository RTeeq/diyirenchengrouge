-- ============================================================================
-- AwakeningSystem.lua — 觉醒系统
-- 分解物品获取觉醒点，三级觉醒解锁/强化组合技
-- ============================================================================

local GameConfig = require("config.GameConfig")

local AwakeningSystem = {}

-- ---------------------------------------------------------------------------
-- 状态
-- ---------------------------------------------------------------------------
local awakeningPoints_ = 0   -- 当前觉醒点
local awakeningLevel_  = 0   -- 觉醒等级 0~5

-- ---------------------------------------------------------------------------
-- 常量（会被 GameConfig.Awakening 覆盖）
-- ---------------------------------------------------------------------------
local LEVEL_THRESHOLDS = { 500, 2000, 5000, 10000, 20000 }

local DISMANTLE_BASE = {
    [1] = 5,    -- 普通
    [2] = 15,   -- 优秀
    [3] = 40,   -- 稀有
    [4] = 100,  -- 史诗
    [5] = 250,  -- 传说
}

local DISMANTLE_AFFIX_BONUS = {
    [1] = 2,    -- 普通词条
    [2] = 5,    -- 中级
    [3] = 12,   -- 高级
    [4] = 30,   -- 顶级
    [5] = 80,   -- 史诗
    [6] = 200,  -- 至臻
}

local LEVEL_NAMES = { "未觉醒", "觉醒", "二次觉醒", "三次觉醒", "四次觉醒", "五次觉醒" }
local LEVEL_COLORS = {
    { 150, 150, 150 }, -- 0: 灰
    { 100, 200, 255 }, -- 1: 蓝
    { 255, 180, 50 },  -- 2: 金
    { 255, 80, 80 },   -- 3: 红
    { 200, 50, 255 },  -- 4: 紫
    { 255, 215, 0 },   -- 5: 耀金
}
local LEVEL_ICONS = { "", "✦", "✦✦", "✦✦✦", "✦✦✦✦", "✦✦✦✦✦" }

-- ---------------------------------------------------------------------------
-- 初始化 / 重置
-- ---------------------------------------------------------------------------

function AwakeningSystem.Init()
    awakeningPoints_ = 0
    awakeningLevel_  = 0
    -- 从 GameConfig 覆盖（如果存在）
    local cfg = GameConfig.Awakening
    if cfg then
        if cfg.LevelThresholds then LEVEL_THRESHOLDS = cfg.LevelThresholds end
        if cfg.DismantleBase then DISMANTLE_BASE = cfg.DismantleBase end
        if cfg.DismantleAffixBonus then DISMANTLE_AFFIX_BONUS = cfg.DismantleAffixBonus end
        if cfg.LevelNames then LEVEL_NAMES = cfg.LevelNames end
        if cfg.LevelColors then LEVEL_COLORS = cfg.LevelColors end
        if cfg.LevelIcons then LEVEL_ICONS = cfg.LevelIcons end
    end
end

function AwakeningSystem.Reset()
    -- 觉醒点跟随存档，新建存档时归零（与金币/水晶一致）
    awakeningPoints_ = 0
    awakeningLevel_  = 0
    local cfg = GameConfig.Awakening
    if cfg then
        if cfg.LevelThresholds then LEVEL_THRESHOLDS = cfg.LevelThresholds end
        if cfg.DismantleBase then DISMANTLE_BASE = cfg.DismantleBase end
        if cfg.DismantleAffixBonus then DISMANTLE_AFFIX_BONUS = cfg.DismantleAffixBonus end
        if cfg.LevelNames then LEVEL_NAMES = cfg.LevelNames end
        if cfg.LevelColors then LEVEL_COLORS = cfg.LevelColors end
        if cfg.LevelIcons then LEVEL_ICONS = cfg.LevelIcons end
    end
end

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------

--- 获取觉醒等级 (0~5)
function AwakeningSystem.GetLevel()
    return awakeningLevel_
end

--- 获取当前觉醒点
function AwakeningSystem.GetPoints()
    return awakeningPoints_
end

--- 获取下一级所需总觉醒点（已满级返回 -1）
function AwakeningSystem.GetPointsForNext()
    if awakeningLevel_ >= #LEVEL_THRESHOLDS then
        return -1
    end
    return LEVEL_THRESHOLDS[awakeningLevel_ + 1]
end

--- 获取觉醒等级名称
function AwakeningSystem.GetLevelName(level)
    level = level or awakeningLevel_
    return LEVEL_NAMES[(level or 0) + 1] or "未觉醒"
end

--- 获取觉醒等级颜色
function AwakeningSystem.GetLevelColor(level)
    level = level or awakeningLevel_
    return LEVEL_COLORS[(level or 0) + 1] or { 150, 150, 150 }
end

--- 获取觉醒等级图标
function AwakeningSystem.GetLevelIcon(level)
    level = level or awakeningLevel_
    return LEVEL_ICONS[(level or 0) + 1] or ""
end

--- 是否已满级
function AwakeningSystem.IsMaxLevel()
    return awakeningLevel_ >= #LEVEL_THRESHOLDS
end

-- ---------------------------------------------------------------------------
-- 觉醒点操作
-- ---------------------------------------------------------------------------

--- 增加觉醒点（不自动升级）
function AwakeningSystem.AddPoints(amount)
    if amount <= 0 then return end
    awakeningPoints_ = awakeningPoints_ + amount
    print("[AwakeningSystem] 获得觉醒点 +" .. amount .. " (总计: " .. awakeningPoints_ .. ")")
end

--- 是否可以觉醒（点数够且未满级）
function AwakeningSystem.CanAwaken()
    if awakeningLevel_ >= #LEVEL_THRESHOLDS then return false end
    return awakeningPoints_ >= LEVEL_THRESHOLDS[awakeningLevel_ + 1]
end

--- 执行觉醒
---@return boolean 是否成功
function AwakeningSystem.DoAwaken()
    if not AwakeningSystem.CanAwaken() then return false end
    awakeningLevel_ = awakeningLevel_ + 1
    print("[AwakeningSystem] 觉醒成功! 等级: " .. awakeningLevel_ .. " (" .. AwakeningSystem.GetLevelName() .. ")")
    return true
end

-- ---------------------------------------------------------------------------
-- 分解计算
-- ---------------------------------------------------------------------------

--- 计算物品分解获得的觉醒点
---@param item table 物品实例
---@return number 觉醒点数
function AwakeningSystem.CalcDismantlePoints(item)
    if not item then return 0 end
    -- 铁剑不可分解
    if item.baseId == "iron_sword" then return 0 end

    -- 基础点数（按品级）
    local base = DISMANTLE_BASE[item.rarity or 1] or 5

    -- 词条加成
    local affixBonus = 0
    if item.affixes then
        for _, affix in ipairs(item.affixes) do
            local tier = affix.tier or 1
            affixBonus = affixBonus + (DISMANTLE_AFFIX_BONUS[tier] or 2)
        end
    end

    return base + affixBonus
end

-- ---------------------------------------------------------------------------
-- 存档
-- ---------------------------------------------------------------------------

function AwakeningSystem.GetSaveData()
    return {
        points = awakeningPoints_,
        level  = awakeningLevel_,
    }
end

function AwakeningSystem.LoadSaveData(data)
    if not data then return end
    awakeningPoints_ = data.points or 0
    awakeningLevel_  = data.level or 0
end

return AwakeningSystem
