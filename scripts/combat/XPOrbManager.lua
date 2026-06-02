-- ============================================================================
-- XPOrbManager.lua — 经验球管理器
-- 敌人死亡掉落经验球，散开→被玩家吸引→收集
-- ============================================================================

local GameConfig = require("config.GameConfig")
local LevelSystem = require("combat.LevelSystem")
local AudioManager = require("core.AudioManager")
local AwakeningSystem = require("systems.AwakeningSystem")

---@type table
local KillBonusSystem_ = nil  -- 延迟加载，避免循环依赖

local XPOrbManager = {}

---@type Scene
local scene_ = nil
local orbs_ = {}      -- { node, vel, phase, life, scatterTimer }
local nextId_ = 1
local xpSfxCooldown_ = 0  -- 经验球音效节流计时器

-- ============================================================================
-- 初始化 / 重置
-- ============================================================================

---@param scene Scene
function XPOrbManager.Init(scene)
    scene_ = scene
    orbs_ = {}
    nextId_ = 1
    print("[XPOrbManager] 初始化完成")
end

function XPOrbManager.Reset()
    for _, orb in pairs(orbs_) do
        if orb.node then orb.node:Remove() end
    end
    orbs_ = {}
    nextId_ = 1
end

-- ============================================================================
-- 生成经验球
-- ============================================================================

--- 在指定位置生成经验球
---@param pos Vector3 掉落位置
---@param count number 球数量
---@param monsterLvl number|nil 怪物等级（每级 +20% 经验）
function XPOrbManager.SpawnOrbs(pos, count, monsterLvl)
    if not scene_ then return end
    local cfg = GameConfig.Leveling
    local lvl = monsterLvl or 1

    for i = 1, count do
        local id = nextId_
        nextId_ = nextId_ + 1

        local node = scene_:CreateChild("XPOrb_" .. id)
        node.position = Vector3(pos.x, pos.y + 0.5, pos.z)

        -- 小球模型
        local mdl = node:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local orbColor = Color(0.3, 0.9, 1.0, 1.0)
        local mat = GameConfig.CreateEmissiveMaterial(orbColor, 3.0)
        mdl:SetMaterial(mat)
        node.scale = Vector3(0.12, 0.12, 0.12)

        -- 点光源
        local pl = node:CreateComponent("Light")
        pl.lightType = LIGHT_POINT
        pl.castShadows = false
        pl.range = 2.0
        pl.color = Color(0.3, 0.8, 1.0, 1.0)
        pl.brightness = 1.5

        -- 随机散开方向
        local angle = math.random() * 6.28
        local speed = 3.0 + math.random() * 2.0
        local vy = 4.0 + math.random() * 2.0

        orbs_[id] = {
            id = id,
            node = node,
            velX = math.cos(angle) * speed,
            velY = vy,
            velZ = math.sin(angle) * speed,
            scatterTimer = cfg.OrbScatterTime,
            phase = math.random() * 6.28,
            life = 30.0,  -- 30秒后消失
            monsterLvl = lvl,  -- 怪物等级（影响经验倍率）
        }
    end
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

---@param dt number
---@param playerPos Vector3
function XPOrbManager.Update(dt, playerPos)
    if not playerPos then return end

    local cfg = GameConfig.Leveling
    -- 延迟加载 KillBonusSystem（避免循环依赖）
    if not KillBonusSystem_ then
        KillBonusSystem_ = require("combat.KillBonusSystem")
    end
    local orbRangeMult = KillBonusSystem_.GetOrbRangeMult()
    local collectDist = cfg.OrbCollectDist * orbRangeMult
    local magnetDist  = cfg.OrbMagnetDist * orbRangeMult
    local toRemove = {}
    xpSfxCooldown_ = math.max(0, xpSfxCooldown_ - dt)

    for id, orb in pairs(orbs_) do
        orb.life = orb.life - dt

        if orb.life <= 0 then
            table.insert(toRemove, id)
        else
            local pos = orb.node.position

            if orb.scatterTimer > 0 then
                -- 散开阶段：物理抛射
                orb.scatterTimer = orb.scatterTimer - dt
                orb.velY = orb.velY - 15.0 * dt  -- 重力
                orb.node.position = Vector3(
                    pos.x + orb.velX * dt,
                    math.max(0.15, pos.y + orb.velY * dt),
                    pos.z + orb.velZ * dt
                )
                -- 落地后速度衰减
                if pos.y <= 0.2 then
                    orb.velY = math.abs(orb.velY) * 0.3
                    orb.velX = orb.velX * 0.5
                    orb.velZ = orb.velZ * 0.5
                end
            else
                -- 吸引阶段
                local dx = playerPos.x - pos.x
                local dy = (playerPos.y + 0.8) - pos.y  -- 对准玩家腰部
                local dz = playerPos.z - pos.z
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

                -- 觉醒LV3以上：全图自动吸引
                local globalMagnet = AwakeningSystem.GetLevel() >= 3

                if dist < collectDist then
                    -- 收集！经验值按怪物等级加成（每级 +20%）
                    local xpMult = 1.0 + (orb.monsterLvl - 1) * GameConfig.Enemies.Wave.XPPerLevelMult
                    local xpGain = math.floor(cfg.XPPerOrb * xpMult)
                    LevelSystem.AddXP(xpGain)
                    -- 节流播放收集音效（每0.08秒最多一次）
                    if xpSfxCooldown_ <= 0 then
                        AudioManager.PlayXPCollect()
                        xpSfxCooldown_ = 0.08
                    end
                    table.insert(toRemove, id)
                elseif globalMagnet or dist < magnetDist then
                    -- 被吸引飞向玩家（全图吸引时用更快的速度）
                    local speed = cfg.OrbSpeed * (1.0 + (magnetDist - dist) / magnetDist)
                    if globalMagnet and dist >= magnetDist then
                        speed = math.max(speed, dist * 2.0)  -- 远距离时加速追赶
                    end
                    local nx, ny, nz = dx / dist, dy / dist, dz / dist
                    orb.node.position = Vector3(
                        pos.x + nx * speed * dt,
                        pos.y + ny * speed * dt,
                        pos.z + nz * speed * dt
                    )
                else
                    -- 悬浮等待
                    orb.phase = orb.phase + dt * 3.0
                    orb.node.position = Vector3(pos.x, 0.3 + math.sin(orb.phase) * 0.1, pos.z)
                end
            end

            -- 旋转动画
            orb.node.rotation = orb.node.rotation * Quaternion(dt * 180, Vector3.UP)
        end
    end

    -- 移除失效经验球
    for _, id in ipairs(toRemove) do
        local orb = orbs_[id]
        if orb and orb.node then
            orb.node:Remove()
        end
        orbs_[id] = nil
    end
end

--- 获取当前经验球数量（调试用）
---@return number
function XPOrbManager.GetOrbCount()
    local n = 0
    for _ in pairs(orbs_) do n = n + 1 end
    return n
end

return XPOrbManager
