-- ============================================================================
-- WeatherSkySystem.lua — 天气/天空/氛围系统
-- 管理 Zone（环境光/雾）、LightGroup（IBL+方向光）、天气粒子、难度氛围
-- ============================================================================

local WeatherSkySystem = {}

-- ============================================================================
-- 默认氛围（安全区晴天）
-- ============================================================================

local DEFAULT_ATMOSPHERE = {
    weather = "clear",
    lightGroup = "Daytime",
    ambientColor = Color(0.03, 0.04, 0.05, 1),
    fogColor = Color(0.5, 0.7, 1.0, 1),
    fogStart = 50, fogEnd = 200,
    sunColor = Color(1.0, 0.93, 0.9, 1),
    sunBrightness = 3.0,
}

-- ============================================================================
-- 内部状态
-- ============================================================================

---@type Scene
local scene_ = nil
---@type Zone
local zone_ = nil
---@type Light
local sunLight_ = nil
---@type Node
local sunNode_ = nil
---@type Node
local lightGroupNode_ = nil
local currentPreset_ = nil  -- 当前 LightGroup 预设名

-- 过渡插值状态
local transitioning_ = false
local transitionTime_ = 0
local transitionDuration_ = 2.0  -- 2秒平滑过渡
local fromAtm_ = nil  -- 过渡起始氛围快照
local targetAtm_ = nil  -- 目标氛围

-- 当前实际应用的氛围值（用于快照）
local currentValues_ = {
    ambientColor = Color(0.03, 0.04, 0.05, 1),
    fogColor = Color(0.5, 0.7, 1.0, 1),
    fogStart = 50, fogEnd = 200,
    sunColor = Color(1.0, 0.93, 0.9, 1),
    sunBrightness = 3.0,
}

-- 天气粒子
---@type Node
local rainNode_ = nil
---@type ParticleEmitter
local rainEmitter_ = nil
---@type Node
local smokeNode_ = nil
---@type ParticleEmitter
local smokeEmitter_ = nil

-- 火光脉动
local fireGlowActive_ = false
local fireGlowTime_ = 0

-- 自动闪电
local lightningActive_ = false
local lightningTimer_ = 0
local lightningIntervalMin_ = 3
local lightningIntervalMax_ = 8
local lightningCallback_ = nil  -- 从 main.lua 注入的闪电+雷声回调

-- ============================================================================
-- 辅助函数
-- ============================================================================

local function lerp(a, b, t)
    return a + (b - a) * t
end

--- 快照当前氛围值
local function snapshotCurrent()
    return {
        ambientColor = Color(currentValues_.ambientColor.r, currentValues_.ambientColor.g, currentValues_.ambientColor.b, 1),
        fogColor = Color(currentValues_.fogColor.r, currentValues_.fogColor.g, currentValues_.fogColor.b, 1),
        fogStart = currentValues_.fogStart,
        fogEnd = currentValues_.fogEnd,
        sunColor = Color(currentValues_.sunColor.r, currentValues_.sunColor.g, currentValues_.sunColor.b, 1),
        sunBrightness = currentValues_.sunBrightness,
    }
end

-- ============================================================================
-- LightGroup 切换（基于 DayNightCycle.lua 模式）
-- ============================================================================

local function switchLightGroup(presetName)
    if not scene_ or not presetName then return end
    if currentPreset_ == presetName then return end

    -- 移除旧的 LightGroup
    if lightGroupNode_ then
        lightGroupNode_:Remove()
        lightGroupNode_ = nil
        zone_ = nil
        sunLight_ = nil
        sunNode_ = nil
    end

    -- 加载新 LightGroup
    lightGroupNode_ = scene_:InstantiateXML(
        "LightGroup/" .. presetName .. ".xml",
        Vector3.ZERO, Quaternion.IDENTITY, LOCAL
    )

    if lightGroupNode_ then
        -- 获取 Zone 组件
        zone_ = lightGroupNode_:GetComponent("Zone")
        -- 获取方向光
        local dlNode = lightGroupNode_:GetChild("Directional Light")
        if dlNode then
            sunNode_ = dlNode
            sunLight_ = dlNode:GetComponent("Light")
        end
    end

    currentPreset_ = presetName
    print("[WeatherSky] LightGroup 切换为: " .. presetName)
end

-- ============================================================================
-- 天气粒子创建
-- ============================================================================

--- 创建雨粒子效果
---@param numParticles number 粒子数量
local function createRainEffect(numParticles)
    if rainNode_ then
        rainNode_:Remove()
        rainNode_ = nil
        rainEmitter_ = nil
    end

    rainNode_ = scene_:CreateChild("__weather_rain__")

    -- 程序化创建粒子效果
    local effect = ParticleEffect:new()
    effect.numParticles = numParticles
    effect.emitterType = EMITTER_BOX
    effect.emitterSize = Vector3(40, 1, 40)
    effect.minDirection = Vector3(-0.05, -1, -0.05)
    effect.maxDirection = Vector3(0.05, -1, 0.05)
    effect.minVelocity = 18.0
    effect.maxVelocity = 28.0
    effect.minTimeToLive = 0.6
    effect.maxTimeToLive = 1.2
    effect.minParticleSize = Vector2(0.03, 0.15)
    effect.maxParticleSize = Vector2(0.05, 0.25)
    effect.minEmissionRate = numParticles * 2.0
    effect.maxEmissionRate = numParticles * 2.5
    effect.relative = false
    effect.sorted = false
    effect.constantForce = Vector3(0, -5, 0)

    -- 雨滴颜色：半透明白/淡蓝
    effect:SetNumColorFrames(2)
    effect:SetColorFrame(0, ColorFrame(Color(0.7, 0.8, 1.0, 0.4), 0.0))
    effect:SetColorFrame(1, ColorFrame(Color(0.5, 0.6, 0.9, 0.0), 1.0))

    -- 设置材质（使用粒子默认材质）
    local mat = cache:GetResource("Material", "Materials/Particle.xml")
    if mat then
        effect:SetMaterial(mat)
    end

    local emitter = rainNode_:CreateComponent("ParticleEmitter")
    emitter:SetEffect(effect)
    emitter:SetEmitting(true)
    rainEmitter_ = emitter

    print("[WeatherSky] 创建雨粒子: " .. numParticles .. " 个")
end

--- 创建烟雾粒子效果（炼狱专属）
local function createSmokeEffect()
    if smokeNode_ then
        smokeNode_:Remove()
        smokeNode_ = nil
        smokeEmitter_ = nil
    end

    smokeNode_ = scene_:CreateChild("__weather_smoke__")

    local effect = ParticleEffect:new()
    effect.numParticles = 150
    effect.emitterType = EMITTER_BOX
    effect.emitterSize = Vector3(50, 5, 50)
    effect.minDirection = Vector3(-1, 0.2, -1)
    effect.maxDirection = Vector3(1, 0.5, 1)
    effect.minVelocity = 0.5
    effect.maxVelocity = 1.5
    effect.minTimeToLive = 4.0
    effect.maxTimeToLive = 8.0
    effect.minParticleSize = Vector2(3.0, 3.0)
    effect.maxParticleSize = Vector2(6.0, 6.0)
    effect.minEmissionRate = 15
    effect.maxEmissionRate = 25
    effect.relative = false
    effect.sorted = false
    effect.sizeAdd = 0.5
    effect.dampingForce = 0.3

    -- 黑紫色半透明烟雾
    effect:SetNumColorFrames(3)
    effect:SetColorFrame(0, ColorFrame(Color(0.05, 0.01, 0.05, 0.0), 0.0))
    effect:SetColorFrame(1, ColorFrame(Color(0.08, 0.02, 0.06, 0.25), 0.3))
    effect:SetColorFrame(2, ColorFrame(Color(0.03, 0.01, 0.03, 0.0), 1.0))

    local mat = cache:GetResource("Material", "Materials/Particle.xml")
    if mat then
        effect:SetMaterial(mat)
    end

    local emitter = smokeNode_:CreateComponent("ParticleEmitter")
    emitter:SetEffect(effect)
    emitter:SetEmitting(true)
    smokeEmitter_ = emitter

    print("[WeatherSky] 创建烟雾粒子")
end

--- 清理所有天气粒子
local function clearWeatherParticles()
    if rainNode_ then
        rainNode_:Remove()
        rainNode_ = nil
        rainEmitter_ = nil
    end
    if smokeNode_ then
        smokeNode_:Remove()
        smokeNode_ = nil
        smokeEmitter_ = nil
    end
end

-- ============================================================================
-- 氛围应用
-- ============================================================================

--- 直接应用氛围值到 Zone/Light
---@param atm table 氛围参数
local function applyValues(atm)
    if zone_ then
        zone_.ambientColor = atm.ambientColor
        zone_.fogColor = atm.fogColor
        zone_.fogStart = atm.fogStart
        zone_.fogEnd = atm.fogEnd
    end
    if sunLight_ then
        sunLight_.color = atm.sunColor
        sunLight_.brightness = atm.sunBrightness
    end
    -- 更新当前值缓存
    currentValues_.ambientColor = Color(atm.ambientColor.r, atm.ambientColor.g, atm.ambientColor.b, 1)
    currentValues_.fogColor = Color(atm.fogColor.r, atm.fogColor.g, atm.fogColor.b, 1)
    currentValues_.fogStart = atm.fogStart
    currentValues_.fogEnd = atm.fogEnd
    currentValues_.sunColor = Color(atm.sunColor.r, atm.sunColor.g, atm.sunColor.b, 1)
    currentValues_.sunBrightness = atm.sunBrightness
end

--- 插值应用两个氛围之间的值
---@param from table
---@param to table
---@param t number 0~1
local function applyLerped(from, to, t)
    local blended = {
        ambientColor = from.ambientColor:Lerp(to.ambientColor, t),
        fogColor = from.fogColor:Lerp(to.fogColor, t),
        fogStart = lerp(from.fogStart, to.fogStart, t),
        fogEnd = lerp(from.fogEnd, to.fogEnd, t),
        sunColor = from.sunColor:Lerp(to.sunColor, t),
        sunBrightness = lerp(from.sunBrightness, to.sunBrightness, t),
    }
    applyValues(blended)
end

-- ============================================================================
-- 公开 API
-- ============================================================================

--- 初始化天气系统
---@param scene Scene
function WeatherSkySystem.Init(scene)
    scene_ = scene

    -- 移除 VillageBuilder 创建的旧 LightGroup（如果存在）
    local oldLG = scene_:GetChild("LightGroup", true)
    if oldLG then
        oldLG:Remove()
        print("[WeatherSky] 移除旧 LightGroup")
    end

    -- 加载默认 Daytime LightGroup
    switchLightGroup(DEFAULT_ATMOSPHERE.lightGroup)

    -- 扩大 Zone boundingBox 覆盖整个场景
    if zone_ then
        zone_.boundingBox = BoundingBox(Vector3(-500, -500, -500), Vector3(500, 500, 500))
    end

    -- 应用默认氛围
    applyValues(DEFAULT_ATMOSPHERE)
    targetAtm_ = DEFAULT_ATMOSPHERE
    transitioning_ = false

    print("[WeatherSky] 天气系统初始化完成")
end

--- 注入闪电回调函数
---@param fn function(flashes: number)
function WeatherSkySystem.SetLightningCallback(fn)
    lightningCallback_ = fn
end

--- 设置目标氛围（出征时根据难度调用）
---@param atmCfg table 难度的 atmosphere 配置
function WeatherSkySystem.SetAtmosphere(atmCfg)
    if not atmCfg then return end

    -- 快照当前值作为过渡起始
    fromAtm_ = snapshotCurrent()
    targetAtm_ = atmCfg

    -- 启动平滑过渡
    transitioning_ = true
    transitionTime_ = 0

    -- 切换 LightGroup（立即切换 IBL，颜色慢慢插值）
    if atmCfg.lightGroup then
        switchLightGroup(atmCfg.lightGroup)
    end

    -- 天气粒子
    clearWeatherParticles()
    local weather = atmCfg.weather or "clear"
    if weather == "rain" then
        createRainEffect(atmCfg.rainParticles or 300)
    elseif weather == "thunderstorm" then
        createRainEffect(atmCfg.rainParticles or 800)
        createSmokeEffect()
    end

    -- 火光脉动
    fireGlowActive_ = atmCfg.fireGlow or false
    fireGlowTime_ = 0

    -- 自动闪电
    if atmCfg.lightningInterval then
        lightningActive_ = true
        lightningIntervalMin_ = atmCfg.lightningInterval[1] or 3
        lightningIntervalMax_ = atmCfg.lightningInterval[2] or 8
        lightningTimer_ = lightningIntervalMin_ + math.random() * (lightningIntervalMax_ - lightningIntervalMin_)
    else
        lightningActive_ = false
    end

    print("[WeatherSky] 氛围切换: " .. weather)
end

--- 恢复默认晴天氛围（结算/死亡时）
function WeatherSkySystem.ResetToDefault()
    -- 快照当前值
    fromAtm_ = snapshotCurrent()
    targetAtm_ = DEFAULT_ATMOSPHERE

    -- 启动过渡
    transitioning_ = true
    transitionTime_ = 0

    -- 切换回 Daytime
    switchLightGroup(DEFAULT_ATMOSPHERE.lightGroup)

    -- 清理天气粒子
    clearWeatherParticles()

    -- 停止火光/闪电
    fireGlowActive_ = false
    lightningActive_ = false

    print("[WeatherSky] 恢复默认晴天氛围")
end

--- 每帧更新
---@param dt number
---@param playerPos Vector3 玩家位置（用于粒子跟随）
function WeatherSkySystem.Update(dt, playerPos)
    -- 1. 平滑过渡插值
    if transitioning_ and fromAtm_ and targetAtm_ then
        transitionTime_ = transitionTime_ + dt
        local t = math.min(1.0, transitionTime_ / transitionDuration_)
        -- 使用 smoothstep 缓动
        t = t * t * (3 - 2 * t)
        applyLerped(fromAtm_, targetAtm_, t)
        if transitionTime_ >= transitionDuration_ then
            transitioning_ = false
            applyValues(targetAtm_)
        end
    end

    -- 2. 雨粒子跟随玩家（XZ 跟随，Y 固定在上方 15m）
    if rainNode_ and playerPos then
        rainNode_.position = Vector3(playerPos.x, playerPos.y + 15, playerPos.z)
    end

    -- 3. 烟雾粒子跟随玩家（较大范围，较低高度）
    if smokeNode_ and playerPos then
        smokeNode_.position = Vector3(playerPos.x, playerPos.y + 2, playerPos.z)
    end

    -- 4. 火光脉动（炼狱专属）
    if fireGlowActive_ and zone_ and targetAtm_ then
        fireGlowTime_ = fireGlowTime_ + dt
        -- 双频叠加模拟不规则火光闪烁
        local pulse1 = math.sin(fireGlowTime_ * 2.0) * 0.5 + 0.5
        local pulse2 = math.sin(fireGlowTime_ * 5.3 + 1.7) * 0.3 + 0.5
        local pulse = pulse1 * 0.7 + pulse2 * 0.3

        local c1 = targetAtm_.fireGlowColor1 or Color(0.08, 0.01, 0.005, 1)
        local c2 = targetAtm_.fireGlowColor2 or Color(0.04, 0.005, 0.06, 1)
        local glowColor = c1:Lerp(c2, pulse)

        -- 叠加到基础 ambientColor 上
        if not transitioning_ then
            zone_.ambientColor = Color(
                targetAtm_.ambientColor.r + glowColor.r * 0.5,
                targetAtm_.ambientColor.g + glowColor.g * 0.5,
                targetAtm_.ambientColor.b + glowColor.b * 0.5,
                1
            )
            -- 雾色也微弱脉动
            zone_.fogColor = Color(
                targetAtm_.fogColor.r + glowColor.r * 0.15,
                targetAtm_.fogColor.g + glowColor.g * 0.15,
                targetAtm_.fogColor.b + glowColor.b * 0.15,
                1
            )
        end

        -- 方向光也微弱脉动
        if sunLight_ and not transitioning_ then
            local bPulse = 0.8 + pulse * 0.4
            sunLight_.brightness = (targetAtm_.sunBrightness or 0.6) * bPulse
        end
    end

    -- 5. 自动闪电（炼狱专属）
    if lightningActive_ then
        lightningTimer_ = lightningTimer_ - dt
        if lightningTimer_ <= 0 then
            -- 触发闪电
            if lightningCallback_ then
                local flashes = math.random(2, 5)
                lightningCallback_(flashes)
            end
            -- 重置定时器
            lightningTimer_ = lightningIntervalMin_ + math.random() * (lightningIntervalMax_ - lightningIntervalMin_)
        end
    end
end

--- 清理系统
function WeatherSkySystem.Cleanup()
    clearWeatherParticles()
    fireGlowActive_ = false
    lightningActive_ = false
    print("[WeatherSky] 系统已清理")
end

return WeatherSkySystem
