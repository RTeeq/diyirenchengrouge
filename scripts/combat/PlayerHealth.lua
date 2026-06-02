-- ============================================================================
-- PlayerHealth.lua — 玩家血量系统
-- 受伤、死亡、重生、无敌帧
-- ============================================================================

local GameConfig = require("config.GameConfig")
local FirstPersonController = nil  -- 延迟加载，避免循环依赖

local PlayerHealth = {}

local baseMaxHP_ = 100
local maxHPBonus_ = 0
local maxHP_ = 100
local currentHP_ = 100
local isDead_ = false
local invTimer_ = 0
local shielded_ = false

-- 玩家 debuff 状态
local playerSlowTimer_ = 0
local playerSlowMult_ = 1.0    -- 1.0=无减速
local playerBurnTimer_ = 0
local playerBurnDPS_ = 0

-- 回调
local onDamage_ = nil   -- function(currentHP, maxHP, damage) — 普通受击（闪红屏+音效）
local onDOT_ = nil      -- function(currentHP, maxHP, damage) — DOT伤害（不闪屏，仅更新HP条）
local onDeath_ = nil    -- function()
local onHeal_ = nil     -- function(currentHP, maxHP)

-- ============================================================================
-- 初始化 / 更新
-- ============================================================================

function PlayerHealth.Init()
    baseMaxHP_ = GameConfig.Combat.PlayerMaxHP
    maxHPBonus_ = 0
    maxHP_ = baseMaxHP_
    currentHP_ = maxHP_
    isDead_ = false
    invTimer_ = 0
    shielded_ = false
    playerSlowTimer_ = 0
    playerSlowMult_ = 1.0
    playerBurnTimer_ = 0
    playerBurnDPS_ = 0
end

--- 设置最大生命加成（升级属性）
---@param bonus number
function PlayerHealth.SetMaxHPBonus(bonus)
    maxHPBonus_ = bonus
    local newMax = baseMaxHP_ + maxHPBonus_
    -- 如果最大血量增加了，当前血量也相应增加
    if newMax > maxHP_ then
        currentHP_ = currentHP_ + (newMax - maxHP_)
    end
    maxHP_ = newMax
end

---@param dt number
function PlayerHealth.Update(dt)
    if invTimer_ > 0 then
        invTimer_ = invTimer_ - dt
    end

    -- 玩家减速 debuff 倒计时
    if playerSlowTimer_ > 0 then
        playerSlowTimer_ = playerSlowTimer_ - dt
        if playerSlowTimer_ <= 0 then
            playerSlowTimer_ = 0
            playerSlowMult_ = 1.0
        end
    end

    -- 玩家灼烧 DOT
    if playerBurnTimer_ > 0 then
        playerBurnTimer_ = playerBurnTimer_ - dt
        if playerBurnDPS_ > 0 and not isDead_ then
            PlayerHealth.TakeDamageRaw(playerBurnDPS_ * dt)
        end
        if playerBurnTimer_ <= 0 then
            playerBurnTimer_ = 0
            playerBurnDPS_ = 0
        end
    end
end

-- ============================================================================
-- 伤害 / 治疗
-- ============================================================================

---@param amount number
function PlayerHealth.TakeDamage(amount)
    if isDead_ then return end
    if invTimer_ > 0 or shielded_ then return end

    -- 闪现无敌帧
    if not FirstPersonController then
        FirstPersonController = require("core.FirstPersonController")
    end
    if FirstPersonController.IsDashInvincible and FirstPersonController.IsDashInvincible() then
        return
    end

    currentHP_ = math.max(0, currentHP_ - amount)
    invTimer_ = GameConfig.Combat.InvincibilityTime

    if onDamage_ then
        onDamage_(currentHP_, maxHP_, amount)
    end

    if currentHP_ <= 0 then
        isDead_ = true
        if onDeath_ then onDeath_() end
    end
end

--- 无视无敌帧的直接伤害（DOT用，不触发闪屏/音效）
---@param amount number
function PlayerHealth.TakeDamageRaw(amount)
    if isDead_ then return end
    currentHP_ = math.max(0, currentHP_ - amount)
    -- DOT 使用专用回调（仅更新血条，不闪屏不播音效）
    if onDOT_ then onDOT_(currentHP_, maxHP_, amount) end
    if currentHP_ <= 0 then
        isDead_ = true
        if onDeath_ then onDeath_() end
    end
end

---@param amount number
function PlayerHealth.Heal(amount)
    if isDead_ then return end
    currentHP_ = math.min(maxHP_, currentHP_ + amount)
    if onHeal_ then onHeal_(currentHP_, maxHP_) end
end

function PlayerHealth.Respawn()
    maxHP_ = baseMaxHP_ + maxHPBonus_
    currentHP_ = maxHP_
    isDead_ = false
    invTimer_ = 2.0
    shielded_ = false
    playerSlowTimer_ = 0
    playerSlowMult_ = 1.0
    playerBurnTimer_ = 0
    playerBurnDPS_ = 0
end

---@param v boolean
function PlayerHealth.SetShielded(v) shielded_ = v end
function PlayerHealth.IsShielded() return shielded_ end

-- ============================================================================
-- 查询
-- ============================================================================

function PlayerHealth.GetHP() return currentHP_ end
function PlayerHealth.GetMaxHP() return maxHP_ end
function PlayerHealth.GetPercent() return currentHP_ / maxHP_ end
function PlayerHealth.IsDead() return isDead_ end

-- ============================================================================
-- 玩家 Debuff 接口
-- ============================================================================

--- 对玩家施加减速
---@param mult number 速度倍率（0.5=减速50%）
---@param duration number 持续秒数
function PlayerHealth.ApplyPlayerSlow(mult, duration)
    if isDead_ then return end
    playerSlowMult_ = math.min(playerSlowMult_, mult)  -- 取更强的减速
    playerSlowTimer_ = math.max(playerSlowTimer_, duration)
end

--- 对玩家施加灼烧DOT
---@param dps number 每秒伤害
---@param duration number 持续秒数
function PlayerHealth.ApplyPlayerBurn(dps, duration)
    if isDead_ then return end
    playerBurnDPS_ = math.max(playerBurnDPS_, dps)
    playerBurnTimer_ = math.max(playerBurnTimer_, duration)
end

--- 获取当前减速倍率（1.0=无减速）
---@return number
function PlayerHealth.GetSlowMult()
    return (playerSlowTimer_ > 0) and playerSlowMult_ or 1.0
end

--- 玩家是否正在灼烧
---@return boolean
function PlayerHealth.IsBurning()
    return playerBurnTimer_ > 0
end

-- ============================================================================
-- 回调注册
-- ============================================================================

function PlayerHealth.OnDamage(cb) onDamage_ = cb end
function PlayerHealth.OnDOT(cb) onDOT_ = cb end
function PlayerHealth.OnDeath(cb) onDeath_ = cb end
function PlayerHealth.OnHeal(cb) onHeal_ = cb end

--- 重新读取 GameConfig 中的 PlayerMaxHP，保留当前血量比例
function PlayerHealth.ApplyConfig()
    local oldMax = maxHP_
    baseMaxHP_ = GameConfig.Combat.PlayerMaxHP
    maxHP_ = baseMaxHP_ + maxHPBonus_
    if oldMax > 0 then
        currentHP_ = math.min(maxHP_, currentHP_ + math.max(0, maxHP_ - oldMax))
    end
end

return PlayerHealth
