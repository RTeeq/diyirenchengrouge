-- ============================================================================
-- DifficultySystem.lua — 难度关卡系统
-- 4个难度等级：简单/普通/困难/炼狱
-- 影响敌人属性、刷怪频率、掉落品质、模型特效、经验金币
-- ============================================================================

local DifficultySystem = {}

-- ============================================================================
-- 难度等级配置
-- ============================================================================

---@class DifficultyConfig
---@field id string
---@field name string
---@field icon string
---@field color table {r,g,b}
---@field desc string
---@field hpMult number 敌人血量倍率
---@field dmgMult number 敌人伤害倍率
---@field spdMult number 敌人速度倍率
---@field spawnMult number 刷怪数量倍率
---@field spawnIntervalMult number 刷怪间隔倍率（>1更慢, <1更快）
---@field dropRarityBonus number 稀有度权重加成
---@field xpMult number 经验倍率
---@field goldMult number 金币倍率
---@field glowIntensity number 敌人发光特效强度（0=无）
---@field glowColor table {r,g,b} 发光颜色
---@field extraEliteChance number 额外精英怪出现概率
---@field bossHPMult number Boss血量倍率
---@field bossDmgMult number Boss伤害倍率
---@field scaleMult number 敌人体型倍率

DifficultySystem.Levels = {
    [1] = {
        id = "easy", name = "简单", icon = "🟢",
        color = { 100, 220, 100 },
        desc = "敌人更弱 | 掉落减少 | 适合休闲",
        hpMult = 0.7, dmgMult = 0.7, spdMult = 0.9,
        spawnMult = 0.7, spawnIntervalMult = 1.4,
        dropRarityBonus = 0, xpMult = 0.8, goldMult = 0.8,
        glowIntensity = 0, glowColor = { 0, 0, 0 },
        extraEliteChance = 0, bossHPMult = 0.6, bossDmgMult = 0.6,
        scaleMult = 1.0,
        -- 氛围：晴朗宜人
        atmosphere = {
            weather = "clear",
            lightGroup = "Daytime",
            ambientColor = Color(0.04, 0.05, 0.06, 1),
            fogColor = Color(0.6, 0.8, 1.0, 1),
            fogStart = 60, fogEnd = 250,
            sunColor = Color(1.0, 0.95, 0.88, 1),
            sunBrightness = 3.5,
        },
    },
    [2] = {
        id = "normal", name = "普通", icon = "🟡",
        color = { 255, 220, 80 },
        desc = "标准体验 | 均衡掉落 | 推荐选择",
        hpMult = 1.0, dmgMult = 1.0, spdMult = 1.0,
        spawnMult = 1.0, spawnIntervalMult = 1.0,
        dropRarityBonus = 0, xpMult = 1.0, goldMult = 1.0,
        glowIntensity = 0, glowColor = { 0, 0, 0 },
        extraEliteChance = 0, bossHPMult = 1.0, bossDmgMult = 1.0,
        scaleMult = 1.0,
        -- 氛围：标准白天
        atmosphere = {
            weather = "clear",
            lightGroup = "Daytime",
            ambientColor = Color(0.03, 0.04, 0.05, 1),
            fogColor = Color(0.5, 0.65, 0.9, 1),
            fogStart = 50, fogEnd = 200,
            sunColor = Color(1.0, 0.93, 0.85, 1),
            sunBrightness = 3.0,
        },
    },
    [3] = {
        id = "hard", name = "困难", icon = "🔴",
        color = { 255, 80, 80 },
        desc = "敌人凶猛 | 稀有翻倍 | 勇者挑战",
        hpMult = 1.5, dmgMult = 1.4, spdMult = 1.15,
        spawnMult = 1.3, spawnIntervalMult = 0.75,
        dropRarityBonus = 3, xpMult = 1.5, goldMult = 1.5,
        glowIntensity = 1.5, glowColor = { 1.0, 0.2, 0.1 },
        extraEliteChance = 0.15, bossHPMult = 1.6, bossDmgMult = 1.5,
        scaleMult = 1.0,
        -- 氛围：阴暗风雨
        atmosphere = {
            weather = "rain",
            lightGroup = "Dusk",
            ambientColor = Color(0.015, 0.018, 0.025, 1),
            fogColor = Color(0.2, 0.22, 0.28, 1),
            fogStart = 20, fogEnd = 100,
            sunColor = Color(0.6, 0.5, 0.45, 1),
            sunBrightness = 1.2,
            rainParticles = 300,
        },
    },
    [4] = {
        id = "hell", name = "炼狱", icon = "💀",
        color = { 200, 50, 255 },
        desc = "地狱降临 | 传说频出 | 极限生存",
        hpMult = 2.5, dmgMult = 2.0, spdMult = 1.3,
        spawnMult = 1.8, spawnIntervalMult = 0.5,
        dropRarityBonus = 8, xpMult = 2.5, goldMult = 2.5,
        glowIntensity = 3.0, glowColor = { 0.7, 0.1, 0.9 },
        extraEliteChance = 0.35, bossHPMult = 2.5, bossDmgMult = 2.0,
        scaleMult = 1.1,
        -- 氛围：雷雨交加 + 黑烟 + 红紫火光
        atmosphere = {
            weather = "thunderstorm",
            lightGroup = "Night",
            ambientColor = Color(0.02, 0.005, 0.015, 1),
            fogColor = Color(0.05, 0.02, 0.06, 1),
            fogStart = 8, fogEnd = 60,
            sunColor = Color(0.8, 0.15, 0.3, 1),
            sunBrightness = 0.6,
            rainParticles = 800,
            lightningInterval = { 3, 8 },
            fireGlow = true,
            fireGlowColor1 = Color(0.08, 0.01, 0.005, 1),
            fireGlowColor2 = Color(0.04, 0.005, 0.06, 1),
        },
    },
}

-- ============================================================================
-- 状态
-- ============================================================================

local currentLevel_ = 2  -- 默认普通

-- ============================================================================
-- 初始化 / 重置
-- ============================================================================

function DifficultySystem.Init()
    -- 不重置 currentLevel_，由存档加载或新建存档设置
    print("[DifficultySystem] 初始化完成，当前难度: " .. DifficultySystem.GetName())
end

function DifficultySystem.Reset()
    currentLevel_ = 2
end

-- ============================================================================
-- 设置 / 查询
-- ============================================================================

---@param level number 1~4
function DifficultySystem.SetLevel(level)
    level = math.max(1, math.min(4, level or 2))
    currentLevel_ = level
    print("[DifficultySystem] 难度设置为: " .. DifficultySystem.GetName())
end

---@return number 1~4
function DifficultySystem.GetLevel()
    return currentLevel_
end

---@return DifficultyConfig
function DifficultySystem.GetConfig()
    return DifficultySystem.Levels[currentLevel_]
end

---@return string
function DifficultySystem.GetName()
    return DifficultySystem.Levels[currentLevel_].name
end

---@return string
function DifficultySystem.GetIcon()
    return DifficultySystem.Levels[currentLevel_].icon
end

---@return table {r,g,b}
function DifficultySystem.GetColor()
    return DifficultySystem.Levels[currentLevel_].color
end

-- ============================================================================
-- 倍率查询 API
-- ============================================================================

function DifficultySystem.GetHPMult()
    return DifficultySystem.Levels[currentLevel_].hpMult
end

function DifficultySystem.GetDmgMult()
    return DifficultySystem.Levels[currentLevel_].dmgMult
end

function DifficultySystem.GetSpdMult()
    return DifficultySystem.Levels[currentLevel_].spdMult
end

function DifficultySystem.GetSpawnMult()
    return DifficultySystem.Levels[currentLevel_].spawnMult
end

function DifficultySystem.GetSpawnIntervalMult()
    return DifficultySystem.Levels[currentLevel_].spawnIntervalMult
end

function DifficultySystem.GetDropRarityBonus()
    return DifficultySystem.Levels[currentLevel_].dropRarityBonus
end

function DifficultySystem.GetXPMult()
    return DifficultySystem.Levels[currentLevel_].xpMult
end

function DifficultySystem.GetGoldMult()
    return DifficultySystem.Levels[currentLevel_].goldMult
end

function DifficultySystem.GetGlowIntensity()
    return DifficultySystem.Levels[currentLevel_].glowIntensity
end

function DifficultySystem.GetGlowColor()
    return DifficultySystem.Levels[currentLevel_].glowColor
end

function DifficultySystem.GetExtraEliteChance()
    return DifficultySystem.Levels[currentLevel_].extraEliteChance
end

function DifficultySystem.GetBossHPMult()
    return DifficultySystem.Levels[currentLevel_].bossHPMult
end

function DifficultySystem.GetBossDmgMult()
    return DifficultySystem.Levels[currentLevel_].bossDmgMult
end

function DifficultySystem.GetScaleMult()
    return DifficultySystem.Levels[currentLevel_].scaleMult
end

-- ============================================================================
-- 存档
-- ============================================================================

function DifficultySystem.GetSaveData()
    return { level = currentLevel_ }
end

function DifficultySystem.LoadSaveData(data)
    if data and data.level then
        currentLevel_ = math.max(1, math.min(4, data.level))
    end
    print("[DifficultySystem] 加载难度: " .. DifficultySystem.GetName())
end

return DifficultySystem
