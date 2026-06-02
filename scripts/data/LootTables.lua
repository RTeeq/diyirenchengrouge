-- ============================================================================
-- LootTables.lua — 掉落表（敌人击杀掉落配置）
-- ============================================================================

local GameConfig = require("config.GameConfig")

local LootTables = {}

-- ============================================================================
-- 掉落率配置（按敌人类型）
-- ============================================================================

local DROP_CONFIG = {
    -- 普通小怪
    melee          = { chance = 0.18, minRarity = 1 },
    ranged         = { chance = 0.18, minRarity = 1 },
    -- 精英怪
    eliteMelee     = { chance = 0.40, minRarity = 2 },
    eliteRanged    = { chance = 0.40, minRarity = 2 },
    eliteAOE       = { chance = 0.45, minRarity = 2 },
    eliteDebuff    = { chance = 0.45, minRarity = 2 },
    -- Boss
    boss           = { chance = 0.80, minRarity = 3 },
    levelBoss      = { chance = 0.80, minRarity = 3 },
    dragonBoss     = { chance = 1.00, minRarity = 3 },
    ultimateBoss   = { chance = 1.00, minRarity = 4 },
}

-- ============================================================================
-- 掉落物品池
-- ============================================================================

-- 武器池（从 GameConfig.Weapons.Order 获取，排除 iron_sword）
local weaponPool_ = nil
-- 装备池（从 GameConfig.Equipment 获取）
local equipPool_ = nil

local function ensurePools()
    if weaponPool_ then return end

    weaponPool_ = {}
    if GameConfig.Weapons and GameConfig.Weapons.Order then
        for _, weaponId in ipairs(GameConfig.Weapons.Order) do
            if weaponId ~= "iron_sword" then
                table.insert(weaponPool_, { baseId = weaponId, category = "weapon" })
            end
        end
    end

    equipPool_ = {}
    if GameConfig.Equipment then
        for equipId, _ in pairs(GameConfig.Equipment) do
            table.insert(equipPool_, { baseId = equipId, category = "equipment" })
        end
    end
end

-- ============================================================================
-- 掉落掷骰
-- ============================================================================

--- 根据敌人类型和等级掷骰掉落
---@param enemyType string 敌人类型
---@param enemyLevel number 敌人等级
---@param isBoss boolean 是否Boss
---@return table|nil 掉落信息 {baseId, category} 或 nil(无掉落)
function LootTables.Roll(enemyType, enemyLevel, isBoss)
    ensurePools()

    local cfg = DROP_CONFIG[enemyType]
    if not cfg then return nil end

    -- 等级提升掉落率（每级+0.5%，上限翻倍但不超过100%）
    local chance = math.min(1.0, cfg.chance + (enemyLevel - 1) * 0.005)

    -- 掷骰判定
    if math.random() > chance then return nil end

    -- 从武器池或装备池中随机选取
    -- 精英和Boss有几率掉装备，普通怪只掉武器
    local pool
    if isBoss or string.sub(enemyType or "", 1, 5) == "elite" then
        -- 30%概率掉装备，70%掉武器
        if #equipPool_ > 0 and math.random() < 0.30 then
            pool = equipPool_
        else
            pool = weaponPool_
        end
    else
        pool = weaponPool_
    end

    if not pool or #pool == 0 then return nil end

    local pick = pool[math.random(1, #pool)]
    return { baseId = pick.baseId, category = pick.category, minRarity = cfg.minRarity }
end

--- 获取指定敌人类型的基础掉落率
---@param enemyType string
---@return number 0~1
function LootTables.GetDropChance(enemyType)
    local cfg = DROP_CONFIG[enemyType]
    return cfg and cfg.chance or 0
end

return LootTables
