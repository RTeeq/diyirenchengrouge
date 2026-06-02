-- ============================================================================
-- KillBonusSystem.lua — 击杀加成系统
-- 每杀10个小怪 → 攻击范围和速度各+2%
-- 每杀1000个小怪 → 解锁被动击杀技能
-- ============================================================================

local GameConfig = require("config.GameConfig")
local EnemyManager = require("combat.EnemyManager")
local PlayerHealth = require("combat.PlayerHealth")
local AudioManager = require("core.AudioManager")

local KillBonusSystem = {}

-- 状态
local lastKillCount_ = 0
local killTier_ = 0          -- 每10击杀 +1
local passiveTier_ = 0       -- 每1000击杀 +1 (最多3)
local orbRangeTier_ = 0      -- 每20击杀 +1（经验球拾取范围加成层数）

-- 被动技能状态
local passiveSkills_ = {}    -- { [id] = true }
local PASSIVE_ORDER = { "bloodthirst", "chain_explosion", "kill_frenzy" }

-- 被动技能内部计时
local chainExplosionCD_ = 0
local killFrenzyTimer_ = 0   -- 狂热剩余时间
local killFrenzyActive_ = false
local killFrenzyStacks_ = 0  -- 连杀计数(5秒内击杀累积)
local killFrenzyResetTimer_ = 0

-- 通知回调
local onMilestone_ = nil     -- function(tier, rangeMult, cdMult) 每10击杀里程碑
local onPassiveUnlock_ = nil -- function(passiveId, passiveName) 被动解锁

-- ============================================================================
-- 被动技能配置
-- ============================================================================

local PASSIVE_DEFS = {
    bloodthirst = {
        name = "嗜血",
        icon = "🩸",
        desc = "每次击杀回复2点生命值",
    },
    chain_explosion = {
        name = "连锁爆炸",
        icon = "💥",
        desc = "击杀敌人时有20%概率对周围4米造成30伤害",
        chance = 0.20,
        range = 4.0,
        damage = 30,
        cooldown = 1.0,
    },
    kill_frenzy = {
        name = "杀戮狂热",
        icon = "🔥",
        desc = "5秒内连续击杀3个敌人后,攻速+30%持续5秒",
        requiredKills = 3,
        window = 5.0,
        duration = 5.0,
        speedBonus = 0.30,
    },
}

-- ============================================================================
-- 公开接口
-- ============================================================================

function KillBonusSystem.Init()
    lastKillCount_ = 0
    killTier_ = 0
    passiveTier_ = 0
    orbRangeTier_ = 0
    passiveSkills_ = {}
    chainExplosionCD_ = 0
    killFrenzyTimer_ = 0
    killFrenzyActive_ = false
    killFrenzyStacks_ = 0
    killFrenzyResetTimer_ = 0
    print("[KillBonusSystem] 初始化完成")
end

function KillBonusSystem.Reset()
    KillBonusSystem.Init()
end

---@param dt number
function KillBonusSystem.Update(dt)
    local currentKills = EnemyManager.GetKillCount()

    -- 检测新击杀
    if currentKills > lastKillCount_ then
        local newKills = currentKills - lastKillCount_
        lastKillCount_ = currentKills

        -- 处理每次新击杀
        for i = 1, newKills do
            KillBonusSystem.OnEnemyKilled()
        end
    end

    -- 更新被动技能计时器
    if chainExplosionCD_ > 0 then
        chainExplosionCD_ = chainExplosionCD_ - dt
    end

    -- 杀戮狂热：连杀窗口计时
    if killFrenzyResetTimer_ > 0 then
        killFrenzyResetTimer_ = killFrenzyResetTimer_ - dt
        if killFrenzyResetTimer_ <= 0 then
            killFrenzyStacks_ = 0
        end
    end

    -- 杀戮狂热：增益持续时间
    if killFrenzyActive_ then
        killFrenzyTimer_ = killFrenzyTimer_ - dt
        if killFrenzyTimer_ <= 0 then
            killFrenzyActive_ = false
            killFrenzyTimer_ = 0
        end
    end

    -- 检查经验球拾取范围加成（每20击杀 +1%）
    local orbInterval = GameConfig.Leveling.OrbRangeKillInterval
    local newOrbTier = math.floor(currentKills / orbInterval)
    if newOrbTier > orbRangeTier_ then
        orbRangeTier_ = newOrbTier
    end

    -- 检查10击杀里程碑
    local newTier = math.floor(currentKills / 10)
    if newTier > killTier_ then
        killTier_ = newTier
        if onMilestone_ then
            onMilestone_(killTier_, KillBonusSystem.GetRangeMult(), KillBonusSystem.GetCooldownMult())
        end
    end

    -- 检查1000击杀里程碑
    local newPassiveTier = math.min(math.floor(currentKills / 1000), #PASSIVE_ORDER)
    if newPassiveTier > passiveTier_ then
        passiveTier_ = newPassiveTier
        -- 解锁新被动
        local passiveId = PASSIVE_ORDER[passiveTier_]
        if passiveId and not passiveSkills_[passiveId] then
            passiveSkills_[passiveId] = true
            if onPassiveUnlock_ then
                local def = PASSIVE_DEFS[passiveId]
                onPassiveUnlock_(passiveId, def and def.name or passiveId)
            end
        end
    end
end

--- 单次击杀处理（触发被动效果）
function KillBonusSystem.OnEnemyKilled()
    -- 嗜血：击杀回血
    if passiveSkills_["bloodthirst"] then
        PlayerHealth.Heal(2)
    end

    -- 连锁爆炸：概率触发AOE
    if passiveSkills_["chain_explosion"] and chainExplosionCD_ <= 0 then
        local def = PASSIVE_DEFS.chain_explosion
        if math.random() < def.chance then
            -- 需要在 WeaponSystem 中注入玩家位置获取
            -- 此处通过 EnemyManager 的 AOEDamage 实现
            local playerPos = KillBonusSystem.GetPlayerPos_()
            if playerPos then
                EnemyManager.AOEDamage(playerPos, def.range, def.damage)
                chainExplosionCD_ = def.cooldown
            end
        end
    end

    -- 杀戮狂热：连杀计数
    if passiveSkills_["kill_frenzy"] then
        local def = PASSIVE_DEFS.kill_frenzy
        killFrenzyStacks_ = killFrenzyStacks_ + 1
        killFrenzyResetTimer_ = def.window

        if killFrenzyStacks_ >= def.requiredKills then
            killFrenzyActive_ = true
            killFrenzyTimer_ = def.duration
            killFrenzyStacks_ = 0
            killFrenzyResetTimer_ = 0
        end
    end
end

-- 玩家位置获取函数（由外部注入）
local getPlayerPos_ = nil

function KillBonusSystem.SetPlayerPosGetter(fn)
    getPlayerPos_ = fn
end

function KillBonusSystem.GetPlayerPos_()
    if getPlayerPos_ then return getPlayerPos_() end
    return nil
end

-- ============================================================================
-- 乘数接口（用于 WeaponSystem 乘数链）
-- ============================================================================

--- 攻击范围乘数：每10击杀 +2%
---@return number
function KillBonusSystem.GetRangeMult()
    return 1.0 + killTier_ * 0.02
end

--- 冷却时间乘数：每10击杀 -2%（乘数越小冷却越短）
---@return number
function KillBonusSystem.GetCooldownMult()
    local mult = 1.0 - killTier_ * 0.02
    return math.max(0.2, mult)  -- 最低0.2（即最多-80%冷却）
end

--- 经验球拾取范围乘数：每20击杀 +1%
---@return number
function KillBonusSystem.GetOrbRangeMult()
    local pct = GameConfig.Leveling.OrbRangeBonusPct
    return 1.0 + orbRangeTier_ * pct
end

--- 获取经验球拾取范围加成层数
---@return number
function KillBonusSystem.GetOrbRangeTier()
    return orbRangeTier_
end

--- 杀戮狂热额外冷却减少
---@return number
function KillBonusSystem.GetFrenzySpeedMult()
    if killFrenzyActive_ then
        return 1.0 - PASSIVE_DEFS.kill_frenzy.speedBonus
    end
    return 1.0
end

-- ============================================================================
-- 查询接口
-- ============================================================================

--- 获取当前击杀层级
---@return number
function KillBonusSystem.GetKillTier()
    return killTier_
end

--- 获取已解锁被动技能列表
---@return table { { id, name, icon, desc } }
function KillBonusSystem.GetPassiveSkills()
    local result = {}
    for _, pid in ipairs(PASSIVE_ORDER) do
        if passiveSkills_[pid] then
            local def = PASSIVE_DEFS[pid]
            table.insert(result, {
                id = pid,
                name = def.name,
                icon = def.icon,
                desc = def.desc,
            })
        end
    end
    return result
end

--- 获取被动技能定义列表（包含未解锁的）
---@return table
function KillBonusSystem.GetAllPassiveDefs()
    local result = {}
    for i, pid in ipairs(PASSIVE_ORDER) do
        local def = PASSIVE_DEFS[pid]
        table.insert(result, {
            id = pid,
            name = def.name,
            icon = def.icon,
            desc = def.desc,
            unlocked = passiveSkills_[pid] == true,
            requiredKills = i * 1000,
        })
    end
    return result
end

--- 杀戮狂热是否激活
---@return boolean
function KillBonusSystem.IsKillFrenzyActive()
    return killFrenzyActive_
end

--- 杀戮狂热剩余时间
---@return number
function KillBonusSystem.GetFrenzyTimeLeft()
    return killFrenzyTimer_
end

-- ============================================================================
-- 回调注册
-- ============================================================================

---@param cb function(tier, rangeMult, cdMult)
function KillBonusSystem.OnMilestone(cb)
    onMilestone_ = cb
end

---@param cb function(passiveId, passiveName)
function KillBonusSystem.OnPassiveUnlock(cb)
    onPassiveUnlock_ = cb
end

return KillBonusSystem
