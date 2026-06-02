-- ============================================================================
-- LevelSystem.lua — 玩家升级系统
-- 经验、等级、属性加成、十级技能
-- ============================================================================

local GameConfig = require("config.GameConfig")

local LevelSystem = {}

-- 状态
local xp_ = 0
local level_ = 1
local xpToNext_ = 100

-- 属性加成累计值
local bonuses_ = {
    attackSpeed = 0,   -- 攻速提升 %（减少冷却）
    maxHP       = 0,   -- 最大生命加成值
    cooldown    = 0,   -- 技能冷却缩减 %
    range       = 0,   -- 攻击范围提升 %
    count       = 0,   -- 额外攻击次数
    attackSize  = 0,   -- 攻击面积提升 %
    attackCount = 0,   -- 额外弹体数量
}

-- 已获得的十级技能
local skills_ = {}           -- { [skillId] = skillConfig }
local skillCooldowns_ = {}   -- { [skillId] = remaining }

-- 待处理的升级队列
local pendingLevelUps_ = 0
local pendingSkillUps_ = 0

-- 回调
local onLevelUp_ = nil    -- function(level, isSkillLevel)
local onXPGain_ = nil     -- function(xp, xpToNext)

-- ============================================================================
-- 初始化 / 重置
-- ============================================================================

function LevelSystem.Init()
    xp_ = 0
    level_ = 1
    xpToNext_ = GameConfig.Leveling.BaseXP
    bonuses_ = { attackSpeed = 0, maxHP = 0, cooldown = 0, range = 0, count = 0, attackSize = 0, attackCount = 0 }
    skills_ = {}
    skillCooldowns_ = {}
    pendingLevelUps_ = 0
    pendingSkillUps_ = 0
end

function LevelSystem.Reset()
    LevelSystem.Init()
end

-- ============================================================================
-- 经验与升级
-- ============================================================================

--- 增加经验值
---@param amount number
function LevelSystem.AddXP(amount)
    xp_ = xp_ + amount
    if onXPGain_ then onXPGain_(xp_, xpToNext_) end

    -- 检查是否升级（可能连升多级）
    while xp_ >= xpToNext_ do
        xp_ = xp_ - xpToNext_
        level_ = level_ + 1
        xpToNext_ = math.floor(GameConfig.Leveling.BaseXP * (GameConfig.Leveling.GrowthRate ^ (level_ - 1)))

        if level_ % 10 == 0 then
            pendingSkillUps_ = pendingSkillUps_ + 1
        end
        pendingLevelUps_ = pendingLevelUps_ + 1

        print("[LevelSystem] 升级！等级: " .. level_)
    end

    -- 触发回调（有待处理的升级时）
    if pendingLevelUps_ > 0 and onLevelUp_ then
        local isSkill = pendingSkillUps_ > 0
        onLevelUp_(level_, isSkill)
    end
end

--- 是否有待处理的升级选择
---@return boolean
function LevelSystem.HasPendingLevelUp()
    return pendingLevelUps_ > 0
end

--- 是否有待处理的技能选择
---@return boolean
function LevelSystem.HasPendingSkillUp()
    return pendingSkillUps_ > 0
end

--- 获取随机 3 个属性选项
---@return table[] 3个属性配置
function LevelSystem.GetAttributeChoices()
    local all = {}
    for i, attr in ipairs(GameConfig.Attributes) do
        table.insert(all, { index = i, attr = attr })
    end
    -- 洗牌取前3个
    for i = #all, 2, -1 do
        local j = math.random(1, i)
        all[i], all[j] = all[j], all[i]
    end
    local choices = {}
    for i = 1, math.min(3, #all) do
        table.insert(choices, all[i].attr)
    end
    return choices
end

--- 获取随机 3 个未拥有的技能选项
---@return table[]
function LevelSystem.GetSkillChoices()
    -- 过滤出未拥有的技能
    local available = {}
    for _, skill in ipairs(GameConfig.LevelSkills) do
        if not skills_[skill.id] then
            table.insert(available, skill)
        end
    end
    -- 如果可选技能 <= 3 个，直接全部返回
    if #available <= 3 then
        return available
    end
    -- 洗牌取前3个
    for i = #available, 2, -1 do
        local j = math.random(1, i)
        available[i], available[j] = available[j], available[i]
    end
    local choices = {}
    for i = 1, 3 do
        choices[i] = available[i]
    end
    return choices
end

--- 玩家选择了一个属性加成
---@param attr table 属性配置（来自 GameConfig.Attributes）
function LevelSystem.ApplyAttribute(attr)
    attr.apply(bonuses_)
    pendingLevelUps_ = pendingLevelUps_ - 1
    print("[LevelSystem] 选择属性: " .. attr.name)

    -- 如果还有待处理的升级，继续触发
    if pendingLevelUps_ > 0 and onLevelUp_ then
        local isSkill = pendingSkillUps_ > 0
        onLevelUp_(level_, isSkill)
    end
end

--- 玩家选择了一个技能
---@param skill table 技能配置（来自 GameConfig.LevelSkills）
function LevelSystem.ApplySkill(skill)
    skills_[skill.id] = skill
    skillCooldowns_[skill.id] = 0
    pendingSkillUps_ = pendingSkillUps_ - 1
    pendingLevelUps_ = pendingLevelUps_ - 1
    print("[LevelSystem] 获得技能: " .. skill.name)

    -- 继续处理剩余升级
    if pendingLevelUps_ > 0 and onLevelUp_ then
        local isSkill = pendingSkillUps_ > 0
        onLevelUp_(level_, isSkill)
    end
end

-- ============================================================================
-- 属性加成查询
-- ============================================================================

--- 获取攻击冷却倍率（越小越快）
---@return number 0~1
function LevelSystem.GetCooldownMult()
    local reduction = (bonuses_.attackSpeed or 0) + (bonuses_.cooldown or 0)
    return math.max(0.1, 1.0 - reduction / 100.0)
end

--- 获取攻击范围倍率
---@return number >=1
function LevelSystem.GetRangeMult()
    return 1.0 + (bonuses_.range or 0) / 100.0
end

--- 获取最大生命加成值
---@return number
function LevelSystem.GetMaxHPBonus()
    return bonuses_.maxHP or 0
end

--- 获取额外攻击次数
---@return number
function LevelSystem.GetExtraHitCount()
    return bonuses_.count or 0
end

--- 获取攻击面积倍率（>=1）
---@return number
function LevelSystem.GetAttackSizeMult()
    return 1.0 + (bonuses_.attackSize or 0) / 100.0
end

--- 获取额外弹体数量
---@return number
function LevelSystem.GetAttackCountBonus()
    return bonuses_.attackCount or 0
end

-- ============================================================================
-- 十级技能
-- ============================================================================

--- 获取已学技能列表
---@return table
function LevelSystem.GetSkills()
    return skills_
end

--- 是否拥有某技能
---@param skillId string
---@return boolean
function LevelSystem.HasSkill(skillId)
    return skills_[skillId] ~= nil
end

--- 获取技能冷却
---@param skillId string
---@return number
function LevelSystem.GetSkillCooldown(skillId)
    return skillCooldowns_[skillId] or 0
end

--- 使用技能（设置冷却）
---@param skillId string
---@return boolean 是否成功
function LevelSystem.UseSkill(skillId)
    local skill = skills_[skillId]
    if not skill then return false end
    if (skillCooldowns_[skillId] or 0) > 0 then return false end
    skillCooldowns_[skillId] = skill.cooldown
    return true
end

--- 覆盖技能冷却（供 SkillSystem 应用冷却加成后调用）
---@param skillId string
---@param cd number
function LevelSystem.SetSkillCooldown(skillId, cd)
    skillCooldowns_[skillId] = cd
end

--- 清除所有技能冷却（广告复活用，保留技能解锁和等级状态）
function LevelSystem.ClearSkillCooldowns()
    for id in pairs(skillCooldowns_) do
        skillCooldowns_[id] = 0
    end
end

--- 更新技能冷却
---@param dt number
function LevelSystem.Update(dt)
    for id, cd in pairs(skillCooldowns_) do
        if cd > 0 then
            skillCooldowns_[id] = math.max(0, cd - dt)
        end
    end
end

-- ============================================================================
-- 只读查询
-- ============================================================================

function LevelSystem.GetLevel() return level_ end
function LevelSystem.GetXP() return xp_ end
function LevelSystem.GetXPToNext() return xpToNext_ end
function LevelSystem.GetBonuses() return bonuses_ end

--- 直接设置等级（开发者用，不触发升级回调）
---@param lv number
function LevelSystem.SetLevel(lv)
    level_ = math.max(1, math.floor(lv))
    xp_ = 0
    xpToNext_ = math.floor(GameConfig.Leveling.BaseXP * (GameConfig.Leveling.GrowthRate ^ (level_ - 1)))
end

--- 直接设置加成数值（开发者用）
---@param key string 加成键名
---@param value number
function LevelSystem.SetBonus(key, value)
    if bonuses_[key] ~= nil then
        bonuses_[key] = value
    end
end

-- ============================================================================
-- 回调
-- ============================================================================

---@param cb function(level, isSkillLevel)
function LevelSystem.OnLevelUp(cb) onLevelUp_ = cb end

---@param cb function(xp, xpToNext)
function LevelSystem.OnXPGain(cb) onXPGain_ = cb end

--- 重新读取 GameConfig.Leveling，刷新 xpToNext_
function LevelSystem.ApplyConfig()
    xpToNext_ = math.floor(GameConfig.Leveling.BaseXP * (GameConfig.Leveling.GrowthRate ^ (level_ - 1)))
end

return LevelSystem
