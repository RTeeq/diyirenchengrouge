-- ============================================================================
-- FirstPersonController.lua — 第一人称控制器（KinematicCharacterController 版）
-- 使用引擎内置 KinematicCharacterController + CharacterComponent
-- 替代了之前有问题的手动 raycast + position 驱动方式
-- ============================================================================

local GameConfig = require("config.GameConfig")
local PlayerHealth = require("combat.PlayerHealth")

local FirstPersonController = {}
FirstPersonController.__index = FirstPersonController

---@type Node
local playerNode_ = nil   -- 角色节点（脚底位置）
---@type Node
local cameraNode_ = nil    -- 相机节点（playerNode_ 的子节点，位于 EyeHeight）
---@type CharacterComponent
local character_ = nil

local yaw_ = 0.0
local pitch_ = 0.0
local enabled_ = true
local speedMult_ = 1.0

-- 基础速度（用于动态倍率计算）
local baseWalkSpeed_ = 0.0
local baseRunSpeed_ = 0.0
local cachedSlowMult_ = -1.0   -- 强制首帧更新

-- 鼠标平滑
local smoothYaw_ = 0.0
local smoothPitch_ = 0.0
local MOUSE_SMOOTH = 0.7
local skipMouseFrames_ = 0          -- 切换鼠标模式后跳过若干帧输入，防止视角跳动

-- 边界限制
local BOUNDARY_LIMIT = 393  -- 略小于边界墙位置(395)

-- 外部输入接口（触控/摇杆注入）
local externalYaw_ = 0.0
local externalPitch_ = 0.0
local joystickX_ = 0.0
local joystickZ_ = 0.0
local externalSprint_ = false
local externalJump_ = false

-- 摇杆死区
local JOYSTICK_DEADZONE = 0.15

-- 闪现状态
local dashCooldownTimer_ = 0       -- 冷却计时器
local lastShiftPressTime_ = 0      -- 上次按下 Shift 的时间
local shiftWasDown_ = false        -- 上一帧 Shift 是否按下（用于检测按下边沿）

-- 闪现体力
local dashStamina_ = 100           -- 当前体力
local dashJustFired_ = false       -- 本帧是否触发了闪现（供 HUD 查询）

-- 闪现特效状态
local dashFxTimer_ = 0             -- 特效剩余时间
local DASH_FX_DURATION = 0.25      -- 特效持续时间 s
local DASH_FOV_BOOST = 25          -- FOV 增加量（度）
local dashSoundRes_ = nil          -- 缓存的音效资源
local dashSoundNode_ = nil         -- 音效节点

-- 闪现无敌帧
local dashInvTimer_ = 0            -- 无敌帧剩余时间

-- 闪现屏幕线条特效
local dashLinesTimer_ = 0          -- 线条特效剩余时间
local DASH_LINES_DURATION = 0.35   -- 线条持续时间 s

-- 组合技状态
local comboState_ = "idle"         -- idle / charging / rushing / active
local comboType_ = "sword_path"    -- sword_path / ice_sweep / fire_sweep / wind_release
local comboChargeTimer_ = 0        -- 蓄力计时
local comboRushTimer_ = 0          -- 冲击计时
local COMBO_RUSH_DURATION = 0.5    -- 冲击持续时间 s（仅 sword_path）
local COMBO_SWEEP_DURATION = 0.35  -- 横扫展开时间 s（ice/fire/wind）
local comboActiveTimer_ = 0        -- 剑道激活计时
local comboTickTimer_ = 0          -- 伤害 tick 计时
local comboFovElapsed_ = 0         -- FOV 恢复独立计时（不受 tick 重置影响）
local comboOrigin_ = nil           -- 剑道起点（世界坐标）
local comboForward_ = nil          -- 剑道方向（水平单位向量）
local comboRushFlash_ = 0          -- 冲击闪白进度 (1→0)
local COMBO_RUSH_FLASH_DUR = 0.3   -- 闪白持续 s
local COMBO_FOV_MAX_BOOST = 30     -- 蓄力最大 FOV 增量（度）
local comboFovBoost_ = 0           -- 当前组合技 FOV 增量
local comboRushJustFired_ = false  -- 冲刺刚触发（用于 HUD 线条生成）
-- 组合技音效缓存
local comboSndCharge_ = nil
local comboSndRush_ = nil
local comboSndWind_ = nil
local comboSndSlashHit_ = nil
local comboSndNode_ = nil
local comboWindSrc_ = nil          -- 刀风循环音源

-- 觉醒强化：多段冲刺（sword_path）
local comboDashTotal_ = 1          -- 总冲刺段数
local comboDashIndex_ = 0          -- 当前冲刺段（1-based）
-- 觉醒强化：风柱持续效果（wind_release lv2/3）
local windPillars_ = {}            -- { {center, radius, height, timer, fallDmg}, ... }
local AwakeningSystem = nil        -- 延迟加载
-- 觉醒4：巨剑吸引状态（sword_path charging 期间吸引敌人）
local giantSwordActive_ = false    -- 巨剑是否已生成
local giantSwordNode_ = nil        -- 巨剑特效引用
-- 觉醒4/5：冰火叠加检测
local iceActiveTimer_ = 0          -- 冰封横扫剩余时间（>0 表示冰封生效中）
local fireActiveTimer_ = 0         -- 烈焰横扫剩余时间（>0 表示烈焰生效中）
local iceFireStaminaRestored_ = false  -- 觉醒4 冰/火首次释放回满体力标记
local iceFireExplosionDone_ = false    -- 本次冰火叠加爆炸是否已触发
-- 觉醒5：剑道冲刺空中飞行+地面冲击
local comboAirDive_ = false        -- 是否在第6次极致冲击（空中→地面）
local comboAirDiveTimer_ = 0       -- 极致冲击计时
local comboAirDiveOrigin_ = nil    -- 起跳位置

-- ============================================================================
-- 初始化
-- ============================================================================

---@param scene Scene
---@return table controller
function FirstPersonController.Create(scene)
    local self = setmetatable({}, FirstPersonController)

    local startPos = GameConfig.Player.StartPosition
    local eyeH = GameConfig.Player.EyeHeight
    local capsuleR = GameConfig.Player.CapsuleRadius
    local capsuleH = GameConfig.Player.CapsuleHeight

    -- 创建角色节点（位于脚底）
    playerNode_ = scene:CreateChild("PlayerBody")
    playerNode_.position = Vector3(startPos.x, startPos.y - eyeH, startPos.z)

    -- 1. RigidBody（真实质量 + 碰撞检测；LinearFactor=ZERO 因为位移由 KCC 驱动）
    local rb = playerNode_:CreateComponent("RigidBody")
    rb:SetCollisionLayerAndMask(CollisionLayerCharacter, CollisionMaskCharacter)
    rb.mass = GameConfig.Player.Mass            -- 80 kg
    rb:SetLinearFactor(Vector3.ZERO)            -- 位移由 KCC 控制，不由物理引擎驱动
    rb:SetAngularFactor(Vector3.ZERO)           -- 旋转由控制器控制
    rb.linearDamping = GameConfig.Player.LinearDamping  -- 0.4
    rb.friction = 0.6                           -- 地面摩擦
    rb.restitution = 0.0                        -- 不弹跳
    rb.collisionEventMode = COLLISION_ALWAYS

    -- 2. 碰撞形状（胶囊体）
    local shape = playerNode_:CreateComponent("CollisionShape")
    shape:SetCapsule(capsuleR * 2, capsuleH, Vector3(0, capsuleH / 2, 0))

    -- 3. KinematicCharacterController（处理实际移动、跳跃、地面检测、台阶爬升）
    local kcc = playerNode_:CreateComponent("KinematicCharacterController")
    kcc:SetCollisionLayerAndMask(CollisionLayerKinematic, CollisionMaskKinematic)
    kcc:SetJumpSpeed(GameConfig.Player.JumpSpeed)
    kcc:SetGravity(Vector3(0, GameConfig.Player.Gravity, 0))  -- -9.81 m/s²
    kcc:SetLinearDamping(GameConfig.Player.LinearDamping)      -- 0.4
    kcc:SetFallSpeed(55.0)     -- 最大下落速度 m/s（终端速度）
    kcc:SetMaxSlope(50.0)      -- 最大可攀爬坡度（度）

    -- 4. CharacterComponent（高层封装：输入 → 移动、空中控制）
    character_ = playerNode_:CreateComponent("CharacterComponent")
    character_:SetAirControlFactor(0.6)

    -- 步行模式：默认步行速度，按 Shift 切换到跑步（冲刺）
    -- GameConfig.Player.MoveSpeed 单位为 cm/s，引擎单位为 m/s，需要 ÷100
    character_:SetEnableWalkMode(true)
    baseWalkSpeed_ = GameConfig.Player.MoveSpeed / 100
    baseRunSpeed_ = GameConfig.Player.MoveSpeed / 100 * GameConfig.Player.SprintMultiplier
    character_:SetWalkSpeed(baseWalkSpeed_)
    character_:SetRunSpeed(baseRunSpeed_)

    -- FPS 模式：不自动转向移动方向
    character_.autoRotateToMoveDir = false
    character_.rotationSpeed = 1440.0

    -- 创建相机节点（作为角色节点的子节点）
    cameraNode_ = playerNode_:CreateChild("PlayerCamera")
    cameraNode_.position = Vector3(0, eyeH, 0)

    -- 添加相机组件
    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip = GameConfig.Camera.NearClip
    camera.farClip = GameConfig.Camera.FarClip
    camera.fov = GameConfig.Camera.FOV

    -- 设置视口
    local viewport = Viewport:new(scene, camera)
    renderer:SetViewport(0, viewport)

    -- 开启 HDR
    renderer.hdrRendering = true

    -- 锁定鼠标
    input.mouseMode = MM_RELATIVE

    -- 初始状态
    yaw_ = 0.0
    pitch_ = 0.0
    speedMult_ = 1.0
    cachedSlowMult_ = -1.0

    -- 5. 碰撞推力系统 — 角色推动动态物体
    SubscribeToEvent(playerNode_, "NodeCollision", "HandlePlayerCollision")

    self.scene_ = scene
    self.playerNode_ = playerNode_
    self.cameraNode_ = cameraNode_

    print("[FPController] KinematicCharacterController 第一人称控制器已创建（Mass=" ..
          GameConfig.Player.Mass .. "kg, Gravity=" .. GameConfig.Player.Gravity .. ")")
    return self
end

-- ============================================================================
-- 碰撞推力 — 角色移动时推动动态 RigidBody
-- ============================================================================

local PUSH_FORCE = 3.0  -- 推力倍率

---@param eventType string
---@param eventData NodeCollisionEventData
function HandlePlayerCollision(eventType, eventData)
    if not enabled_ then return end
    -- 忽略触发器碰撞
    if eventData["Trigger"]:GetBool() then return end

    local otherBody = eventData["OtherBody"]:GetPtr("RigidBody")
    if not otherBody then return end

    -- 只推动动态物体（mass > 0 且非 kinematic）
    if otherBody.mass <= 0 or otherBody.kinematic then return end

    -- 获取 KCC 当前线速度作为推力方向
    local kcc = playerNode_:GetComponent("KinematicCharacterController")
    if not kcc then return end
    local vel = kcc:GetLinearVelocity()
    local speed = vel:Length()
    if speed < 0.5 then return end  -- 速度太低不推

    -- 读取碰撞接触点，计算推力方向
    local contacts = eventData["Contacts"]:GetBuffer()
    while not contacts.eof do
        local contactPos = contacts:ReadVector3()
        local contactNormal = contacts:ReadVector3()
        local contactDist = contacts:ReadFloat()
        local contactImpulse = contacts:ReadFloat()

        -- contactNormal 指向"从对方指向自己"，取反即为推力方向
        -- 但用角色移动方向更自然
        local pushDir = vel:Normalized()
        -- 不往下推（避免把物体按进地面）
        if pushDir.y < 0 then pushDir.y = 0 end

        local force = pushDir * GameConfig.Player.Mass * PUSH_FORCE
        otherBody:ApplyImpulse(force, contactPos)
        break  -- 只用第一个接触点
    end
end

-- ============================================================================
-- 启用/禁用
-- ============================================================================

function FirstPersonController:SetEnabled(enabled)
    enabled_ = enabled
end

function FirstPersonController:IsEnabled()
    return enabled_
end

-- ============================================================================
-- 获取器
-- ============================================================================

---@return Camera
function FirstPersonController:GetCamera()
    return cameraNode_:GetComponent("Camera")
end

---@return Node
function FirstPersonController:GetCameraNode()
    return cameraNode_
end

--- 获取眼睛位置（世界坐标）
---@return Vector3
function FirstPersonController:GetPosition()
    return cameraNode_.worldPosition
end

--- 设置玩家位置（传送用），输入为眼睛位置
---@param pos Vector3 眼睛目标位置
function FirstPersonController:SetPosition(pos)
    local eyeH = GameConfig.Player.EyeHeight
    playerNode_.position = Vector3(pos.x, pos.y - eyeH, pos.z)
end

---@return number yaw
---@return number pitch
function FirstPersonController:GetAngles()
    return yaw_, pitch_
end

---@return boolean
function FirstPersonController:IsMoving()
    if not character_ then return false end
    return character_:IsMoving()
end

---@return boolean
function FirstPersonController:IsSprinting()
    if not character_ then return false end
    return character_:IsMoving() and (input:GetKeyDown(KEY_SHIFT) or externalSprint_)
end

--- 设置移速倍率（装备加成等）
---@param mult number
function FirstPersonController:SetSpeedMult(mult)
    speedMult_ = mult or 1.0
    cachedSlowMult_ = -1.0  -- 强制下一帧更新速度
end

---@return boolean
function FirstPersonController:IsGrounded()
    if not character_ then return true end
    return character_:IsOnGround()
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

---@param dt number 帧时间
function FirstPersonController:Update(dt)
    if not enabled_ then return end

    -- 1. 鼠标/触控视角
    self:HandleMouseLook()

    -- 2. 设置 CharacterComponent 的 controls（移动/跳跃/冲刺）
    self:HandleControls()

    -- 3. 闪现检测（双击 Shift）— 组合技非 idle 时跳过
    if comboState_ == "idle" then
        self:HandleDash(dt)
    else
        -- 组合技激活时仍需更新闪现计时器/体力恢复（但 FOV 由 combo 控制）
        dashJustFired_ = false
        if dashCooldownTimer_ > 0 then dashCooldownTimer_ = dashCooldownTimer_ - dt end
        if dashFxTimer_ > 0 then dashFxTimer_ = dashFxTimer_ - dt end
        if dashLinesTimer_ > 0 then dashLinesTimer_ = dashLinesTimer_ - dt end
        if dashInvTimer_ > 0 then dashInvTimer_ = dashInvTimer_ - dt end
        shiftWasDown_ = input:GetKeyDown(KEY_SHIFT)
    end

    -- 4. 剑道组合技
    self:HandleComboSlash(dt)

    -- 4. 更新相机旋转（使用 worldRotation 避免父节点旋转干扰）
    cameraNode_.worldRotation = Quaternion(pitch_, yaw_, 0)

    -- 5. 动态更新速度（减速效果等），仅在变化时更新
    local slowMult = PlayerHealth.GetSlowMult()
    if slowMult ~= cachedSlowMult_ then
        cachedSlowMult_ = slowMult
        character_:SetWalkSpeed(baseWalkSpeed_ * speedMult_ * slowMult)
        character_:SetRunSpeed(baseRunSpeed_ * speedMult_ * slowMult)
    end

    -- 6. 边界保护
    self:HandleBoundary()
end

-- ============================================================================
-- 鼠标视角控制
-- ============================================================================

function FirstPersonController:HandleMouseLook()
    -- 切换鼠标模式后跳过若干帧，防止 MM_RELATIVE↔MM_ABSOLUTE 切换时的瞬间位移导致视角跳动
    if skipMouseFrames_ > 0 then
        skipMouseFrames_ = skipMouseFrames_ - 1
        smoothYaw_ = 0
        smoothPitch_ = 0
        -- 消费掉本帧的 mouseMoveX/Y（读取即消费），但不应用
        local _ = input.mouseMoveX
        local _ = input.mouseMoveY
        -- 仍然处理外部输入（触控/手柄）以免丢失
        if externalYaw_ ~= 0 or externalPitch_ ~= 0 then
            yaw_ = yaw_ + externalYaw_
            pitch_ = pitch_ + externalPitch_
            externalYaw_ = 0
            externalPitch_ = 0
        end
        pitch_ = Clamp(pitch_, GameConfig.Player.PitchMin, GameConfig.Player.PitchMax)
        return
    end

    local sensitivity = GameConfig.Player.MouseSensitivity
    local mx = input.mouseMoveX * sensitivity
    local my = input.mouseMoveY * sensitivity

    smoothYaw_ = smoothYaw_ + (mx - smoothYaw_) * MOUSE_SMOOTH
    smoothPitch_ = smoothPitch_ + (my - smoothPitch_) * MOUSE_SMOOTH

    yaw_ = yaw_ + smoothYaw_
    pitch_ = pitch_ + smoothPitch_

    -- 外部输入（触控/手柄）
    if externalYaw_ ~= 0 or externalPitch_ ~= 0 then
        yaw_ = yaw_ + externalYaw_
        pitch_ = pitch_ + externalPitch_
        externalYaw_ = 0
        externalPitch_ = 0
    end

    -- 限制俯仰角
    pitch_ = Clamp(pitch_, GameConfig.Player.PitchMin, GameConfig.Player.PitchMax)
end

-- ============================================================================
-- 输入控制 → CharacterComponent controls
-- ============================================================================

function FirstPersonController:HandleControls()
    -- 设置视角方向（CharacterComponent 用此确定移动方向）
    character_.controls.yaw = yaw_
    character_.controls.pitch = pitch_

    -- 蓄力/冲刺期间锁定移动
    if comboState_ == "charging" or comboState_ == "rushing" then
        character_.controls:Set(CTRL_FORWARD, false)
        character_.controls:Set(CTRL_BACK, false)
        character_.controls:Set(CTRL_LEFT, false)
        character_.controls:Set(CTRL_RIGHT, false)
        character_.controls:Set(CTRL_JUMP, false)
        character_.controls:Set(CTRL_RUN, false)
        if externalJump_ then externalJump_ = false end
        return
    end

    -- 键盘移动
    local fwd = input:GetKeyDown(KEY_W)
    local back = input:GetKeyDown(KEY_S)
    local left = input:GetKeyDown(KEY_A)
    local right = input:GetKeyDown(KEY_D)

    -- 摇杆移动（与键盘合并）
    if joystickZ_ > JOYSTICK_DEADZONE then fwd = true end
    if joystickZ_ < -JOYSTICK_DEADZONE then back = true end
    if joystickX_ < -JOYSTICK_DEADZONE then left = true end
    if joystickX_ > JOYSTICK_DEADZONE then right = true end

    character_.controls:Set(CTRL_FORWARD, fwd)
    character_.controls:Set(CTRL_BACK, back)
    character_.controls:Set(CTRL_LEFT, left)
    character_.controls:Set(CTRL_RIGHT, right)

    -- 跳跃
    local jump = input:GetKeyDown(KEY_SPACE) or externalJump_
    character_.controls:Set(CTRL_JUMP, jump)
    if externalJump_ then externalJump_ = false end

    -- 冲刺（CTRL_RUN + enableWalkMode = 默认步行，按住冲刺）
    character_.controls:Set(CTRL_RUN, input:GetKeyDown(KEY_SHIFT) or externalSprint_)
end

-- ============================================================================
-- 边界保护
-- ============================================================================

function FirstPersonController:HandleBoundary()
    local pos = playerNode_.position
    local clamped = false

    if pos.x > BOUNDARY_LIMIT then pos.x = BOUNDARY_LIMIT; clamped = true end
    if pos.x < -BOUNDARY_LIMIT then pos.x = -BOUNDARY_LIMIT; clamped = true end
    if pos.z > BOUNDARY_LIMIT then pos.z = BOUNDARY_LIMIT; clamped = true end
    if pos.z < -BOUNDARY_LIMIT then pos.z = -BOUNDARY_LIMIT; clamped = true end

    -- 防止掉出世界（传送回出生点）
    if pos.y < -5.0 then
        local sp = GameConfig.Player.StartPosition
        local eyeH = GameConfig.Player.EyeHeight
        pos = Vector3(sp.x, sp.y - eyeH, sp.z)
        clamped = true
    end

    if clamped then
        playerNode_.position = pos
    end
end

-- ============================================================================
-- 闪现（双击 Shift + WASD 方向）
-- ============================================================================

function FirstPersonController:HandleDash(dt)
    dashJustFired_ = false

    -- 冷却计时
    if dashCooldownTimer_ > 0 then
        dashCooldownTimer_ = dashCooldownTimer_ - dt
    end

    -- 体力自动恢复
    local maxSt = GameConfig.Player.DashStaminaMax
    if dashStamina_ < maxSt then
        dashStamina_ = math.min(maxSt, dashStamina_ + GameConfig.Player.DashStaminaRegen * dt)
    end

    -- FOV 特效回弹
    if dashFxTimer_ > 0 then
        dashFxTimer_ = dashFxTimer_ - dt
        local cam = cameraNode_:GetComponent("Camera")
        if cam then
            local t = math.max(0, dashFxTimer_ / DASH_FX_DURATION)  -- 1→0
            local fovExtra = DASH_FOV_BOOST * t * t
            cam.fov = GameConfig.Camera.FOV + fovExtra
        end
    end

    -- 线条特效计时
    if dashLinesTimer_ > 0 then
        dashLinesTimer_ = dashLinesTimer_ - dt
    end

    -- 无敌帧计时
    if dashInvTimer_ > 0 then
        dashInvTimer_ = dashInvTimer_ - dt
    end

    -- 检测 Shift 按下边沿（本帧按下 & 上帧未按下）
    local shiftDown = input:GetKeyDown(KEY_SHIFT)
    local shiftPressed = shiftDown and not shiftWasDown_
    shiftWasDown_ = shiftDown

    if not shiftPressed then return end

    -- 双击检测
    local now = time.elapsedTime
    local interval = now - lastShiftPressTime_
    lastShiftPressTime_ = now

    if interval > GameConfig.Player.DashDoubleTap then
        return
    end

    -- 冷却中
    if dashCooldownTimer_ > 0 then return end

    -- 体力不足
    local cost = GameConfig.Player.DashStaminaCost
    if dashStamina_ < cost then return end

    -- === 执行闪现 ===
    dashStamina_ = dashStamina_ - cost
    dashCooldownTimer_ = GameConfig.Player.DashCooldown
    dashJustFired_ = true
    dashInvTimer_ = GameConfig.Player.DashInvDuration

    -- 根据 WASD 计算方向（相对于角色朝向）
    local fwd = input:GetKeyDown(KEY_W)
    local back = input:GetKeyDown(KEY_S)
    local left = input:GetKeyDown(KEY_A)
    local right = input:GetKeyDown(KEY_D)

    local moveX = 0
    local moveZ = 0
    if fwd then moveZ = moveZ + 1 end
    if back then moveZ = moveZ - 1 end
    if right then moveX = moveX + 1 end
    if left then moveX = moveX - 1 end

    -- 没按方向键 → 默认向前闪现
    if moveX == 0 and moveZ == 0 then
        moveZ = 1
    end

    -- 将方向从角色本地坐标转为世界坐标（只用 yaw，忽略 pitch）
    local yawRot = Quaternion(yaw_, Vector3.UP)
    local localDir = Vector3(moveX, 0, moveZ):Normalized()
    local worldDir = yawRot * localDir

    -- 传送
    local pos = playerNode_.position
    local dashDist = GameConfig.Player.DashDistance
    local newPos = pos + worldDir * dashDist
    newPos.y = pos.y
    playerNode_.position = newPos

    -- === 触发特效 ===
    -- FOV 冲击
    dashFxTimer_ = DASH_FX_DURATION
    local cam = cameraNode_:GetComponent("Camera")
    if cam then
        cam.fov = GameConfig.Camera.FOV + DASH_FOV_BOOST
    end

    -- 屏幕线条
    dashLinesTimer_ = DASH_LINES_DURATION

    -- 播放音效
    if not dashSoundRes_ then
        dashSoundRes_ = cache:GetResource("Sound", "audio/sfx/dash_whoosh.ogg")
    end
    if dashSoundRes_ and playerNode_ then
        if not dashSoundNode_ then
            dashSoundNode_ = playerNode_:CreateChild("DashSFX")
        end
        local src = dashSoundNode_:GetOrCreateComponent("SoundSource")
        src:SetSoundType("Effect")
        src:SetGain(0.8)
        src:Play(dashSoundRes_)
    end
end

-- ============================================================================
-- 剑道组合技（Shift + 右键蓄力 → 冲击 → 剑道持续砍击）
-- ============================================================================

local EnemyManager = nil   -- 延迟加载，避免循环依赖
local WeaponSystem = nil

local function ensureComboDeps()
    if not EnemyManager then
        EnemyManager = require("combat.EnemyManager")
    end
    if not WeaponSystem then
        WeaponSystem = require("combat.WeaponSystem")
    end
    if not AwakeningSystem then
        AwakeningSystem = require("systems.AwakeningSystem")
    end
end

local function playComboSound(resField, resPath, gain, loop)
    if not comboSndNode_ then
        comboSndNode_ = playerNode_:CreateChild("ComboSFX")
    end
    if not _G[resField] then
        _G[resField] = cache:GetResource("Sound", resPath)
        if loop and _G[resField] then _G[resField].looped = true end
    end
    local snd = _G[resField]
    if not snd then return nil end
    local src = comboSndNode_:CreateComponent("SoundSource")
    src:SetSoundType("Effect")
    src:SetGain(gain or 0.7)
    src:Play(snd)
    return src
end

--- 组合技是否可用（体力满 + idle 状态）
function FirstPersonController.IsComboAvailable()
    return comboState_ == "idle"
        and dashStamina_ >= GameConfig.Player.DashStaminaMax
end

--- 外部触发蓄力（由 WeaponSystem 在 Shift+WASD+RMB 时调用）
---@param comboType string "sword_path"|"ice_sweep"|"fire_sweep"|"wind_release"
function FirstPersonController.StartComboCharge(comboType)
    if not FirstPersonController.IsComboAvailable() then return false end
    comboState_ = "charging"
    comboType_ = comboType or "sword_path"
    comboChargeTimer_ = 0
    -- 播放蓄力音效
    playComboSound("comboSndCharge_", "audio/sfx/combo_charge.ogg", 0.7, false)
    return true
end

--- 获取当前组合技对应的配置表
local function getComboConfig()
    local p = GameConfig.Player
    if comboType_ == "ice_sweep"     then return p.ComboIceSweep end
    if comboType_ == "fire_sweep"    then return p.ComboFireSweep end
    if comboType_ == "wind_release"  then return p.ComboWindRelease end
    return p.ComboSwordPath  -- sword_path 默认
end

--- 获取当前组合技的激活持续时间
local function getComboDuration()
    local c = getComboConfig()
    return c.SlashDuration or c.Duration
end

function FirstPersonController:HandleComboSlash(dt)
    -- 每帧重置一次性标记
    comboRushJustFired_ = false

    -- 冲击闪白衰减（独立于状态）
    if comboRushFlash_ > 0 then
        comboRushFlash_ = math.max(0, comboRushFlash_ - dt / COMBO_RUSH_FLASH_DUR)
    end

    if comboState_ == "idle" then return end

    local chargeTime = GameConfig.Player.ComboChargeTime

    -- === CHARGING（所有类型共用） ===
    if comboState_ == "charging" then
        comboChargeTimer_ = comboChargeTimer_ + dt

        -- 蓄力期间 FOV 持续扩大
        local chargePct = math.min(1, comboChargeTimer_ / chargeTime)
        comboFovBoost_ = COMBO_FOV_MAX_BOOST * chargePct
        local cam = cameraNode_:GetComponent("Camera")
        if cam then cam.fov = GameConfig.Camera.FOV + comboFovBoost_ end

        -- 觉醒4+ sword_path 蓄力期间：每次冲刺蓄力都生成巨剑并吸引敌人
        if comboType_ == "sword_path" then
            ensureComboDeps()
            local awkLv = AwakeningSystem and AwakeningSystem.GetLevel() or 0
            if awkLv >= 4 and chargePct > 0.3 then
                local yawRot = Quaternion(yaw_, Vector3.UP)
                local fwd = (yawRot * Vector3.FORWARD):Normalized()
                local cfg = GameConfig.Player.ComboSwordPath
                local swordCenter = playerNode_.position + Vector3(0, 0.5, 0) + fwd * (cfg.SlashLength * 0.5)
                -- 生成巨剑特效（每次蓄力一把）
                if not giantSwordActive_ and WeaponSystem and WeaponSystem.CreateGiantSwordEffect then
                    WeaponSystem.CreateGiantSwordEffect(
                        playerNode_.position + Vector3(0, 0.5, 0), fwd,
                        cfg.SlashLength, cfg.SlashWidth * 2, chargeTime - comboChargeTimer_ + 0.5)
                    giantSwordActive_ = true
                end
                -- 每帧吸引 10 米范围内敌人到巨剑中心
                if EnemyManager and EnemyManager.PullEnemiesToPoint then
                    EnemyManager.PullEnemiesToPoint(swordCenter, 10.0, 8.0 * dt)
                end
            end
        end

        -- 检查松开（Shift 或右键松开 → 取消）
        -- 多段冲刺续段（comboDashIndex_ > 1）时自动蓄力，不检查按键
        if comboDashIndex_ <= 1 then
            local shiftHeld = input:GetKeyDown(KEY_SHIFT)
            local rmbHeld = input:GetMouseButtonDown(MOUSEB_RIGHT)
            if not shiftHeld or not rmbHeld then
                comboState_ = "idle"
                comboChargeTimer_ = 0
                comboFovBoost_ = 0
                comboDashTotal_ = 1
                comboDashIndex_ = 0
                giantSwordActive_ = false
                if cam then cam.fov = GameConfig.Camera.FOV end
                if comboSndNode_ then comboSndNode_:Remove(); comboSndNode_ = nil end
                return
            end
        end

        -- 蓄力完成 → 进入 rushing
        if comboChargeTimer_ >= chargeTime then
            dashStamina_ = 0

            local yawRot = Quaternion(yaw_, Vector3.UP)
            comboForward_ = (yawRot * Vector3.FORWARD):Normalized()
            comboOrigin_ = playerNode_.position + Vector3(0, 0.5, 0)

            -- 多段冲刺续段：comboDashIndex_ > 1 说明已经初始化过，直接进入rushing
            if comboDashIndex_ <= 1 then
                -- 首次蓄力完成：初始化多段冲刺参数
                ensureComboDeps()
                local awkLv = AwakeningSystem and AwakeningSystem.GetLevel() or 0
                if comboType_ == "sword_path" then
                    if awkLv >= 3 then
                        comboDashTotal_ = 5  -- lv3/4/5 均为5段冲刺
                    elseif awkLv >= 2 then
                        comboDashTotal_ = 2
                    else
                        comboDashTotal_ = 1
                    end
                else
                    comboDashTotal_ = 1
                end
                comboDashIndex_ = 1
            end
            -- 续段蓄力完成时 comboDashIndex_ 和 comboDashTotal_ 已在rushing结束时设置好

            comboState_ = "rushing"
            comboRushTimer_ = 0
            comboRushFlash_ = 1.0
            comboRushJustFired_ = true
            giantSwordActive_ = false  -- 巨剑蓄力结束
            -- 每次冲刺无敌 1 秒
            dashInvTimer_ = 1.0

            if comboSndNode_ then comboSndNode_:Remove(); comboSndNode_ = nil end
            playComboSound("comboSndRush_", "audio/sfx/combo_rush.ogg", 0.9, false)
            dashLinesTimer_ = DASH_LINES_DURATION * 2
        end
        return
    end

    -- === RUSHING（按类型分行为） ===
    if comboState_ == "rushing" then
        comboRushTimer_ = comboRushTimer_ + dt

        local rushDur
        if comboType_ == "sword_path" then
            rushDur = COMBO_RUSH_DURATION
            -- 觉醒多段冲刺：后续段距离更远
            local cfg = GameConfig.Player.ComboSwordPath
            local distMul = 1.0
            if comboDashIndex_ >= 2 then distMul = 1.5 end  -- 第2段起 1.5x 距离
            local rushSpeed = (cfg.RushDistance * distMul) / COMBO_RUSH_DURATION
            local moveVec = comboForward_ * rushSpeed * dt
            playerNode_.position = playerNode_.position + Vector3(moveVec.x, 0, moveVec.z)

            -- 冲刺撞击：小怪必死，Boss 受巨额伤害
            if EnemyManager and EnemyManager.GetAllEnemies and EnemyManager.DamageEnemy then
                local ppos = playerNode_.position
                local killRadius = (cfg.SlashWidth or 4.0) * 0.5  -- 以剑道宽度一半为碰撞半径
                for eid, e in pairs(EnemyManager.GetAllEnemies()) do
                    if e.node and e.hp and e.hp > 0 then
                        local dx = e.node.position.x - ppos.x
                        local dy = e.node.position.y - ppos.y
                        local dz = e.node.position.z - ppos.z
                        if math.abs(dy) < 3.0 and (dx * dx + dz * dz) <= killRadius * killRadius then
                            local dmg = e.isBoss and 500 or 99999
                            EnemyManager.DamageEnemy(eid, dmg)
                        end
                    end
                end
            end
        else
            -- 冰/火/风：不移动，短暂挥砍展开
            rushDur = COMBO_SWEEP_DURATION
        end

        -- 冲刺/展开期间保持最大 FOV
        local cam = cameraNode_:GetComponent("Camera")
        if cam then cam.fov = GameConfig.Camera.FOV + COMBO_FOV_MAX_BOOST end

        if comboRushTimer_ >= rushDur then
            ensureComboDeps()
            local awkLv = AwakeningSystem and AwakeningSystem.GetLevel() or 0

            -- ── sword_path 多段冲刺：每段结束创建剑道 ──
            if comboType_ == "sword_path" and comboDashTotal_ > 1 then
                local cfg = GameConfig.Player.ComboSwordPath
                -- 当前段的宽度倍率：第2段起 2x 宽度
                local widthMul = (comboDashIndex_ >= 2) and 2.0 or 1.0
                local distMul  = (comboDashIndex_ >= 2) and 1.5 or 1.0
                local segLen   = cfg.SlashLength * distMul

                -- 创建本段剑道
                if EnemyManager and EnemyManager.FreezeEnemiesInRect then
                    EnemyManager.FreezeEnemiesInRect(
                        comboOrigin_, comboForward_,
                        segLen, cfg.SlashWidth * widthMul * 0.5,
                        cfg.FreezeDuration)
                end
                if WeaponSystem and WeaponSystem.CreateSwordPath then
                    WeaponSystem.CreateSwordPath(
                        comboOrigin_, comboForward_,
                        segLen, cfg.SlashWidth * widthMul,
                        cfg.SlashDuration)
                end

                -- 还有后续段 → 恢复满体力并立即进入蓄力状态
                if comboDashIndex_ < comboDashTotal_ then
                    comboDashIndex_ = comboDashIndex_ + 1
                    -- 更新起点为当前位置，重新读取朝向
                    comboOrigin_ = playerNode_.position + Vector3(0, 0.5, 0)
                    local yawRot = Quaternion(yaw_, Vector3.UP)
                    comboForward_ = (yawRot * Vector3.FORWARD):Normalized()
                    -- 恢复满体力
                    dashStamina_ = GameConfig.Player.DashStaminaMax
                    -- 重置巨剑状态，允许下次蓄力再生成
                    giantSwordActive_ = false
                    -- 回到 charging 状态，需要重新蓄力
                    comboState_ = "charging"
                    comboChargeTimer_ = 0
                    -- FOV 先回落到正常，蓄力时再逐渐增大
                    comboFovBoost_ = 0
                    local cam2 = cameraNode_:GetComponent("Camera")
                    if cam2 then cam2.fov = GameConfig.Camera.FOV end
                    playComboSound("comboSndCharge_", "audio/sfx/combo_charge.ogg", 0.7, false)
                    return  -- 回到 charging 状态等待蓄力
                end

                -- 所有段完成
                -- 觉醒5：5段冲刺后增加第6次极致地面冲击
                if awkLv >= 5 then
                    comboAirDive_ = true
                    comboAirDiveTimer_ = 0
                    comboAirDiveOrigin_ = playerNode_.position
                    -- 先飞到空中 20 米
                    playerNode_.position = playerNode_.position + Vector3(0, 20.0, 0)
                    dashInvTimer_ = 3.0  -- 延长无敌
                    comboState_ = "active"
                    comboActiveTimer_ = 1.5  -- 空中滞留 + 下落时间
                    comboTickTimer_ = 0
                    comboFovElapsed_ = 0
                    comboWindSrc_ = playComboSound("comboSndWind_", "audio/sfx/combo_wind.ogg", 0.5, true)
                    return
                end

                -- 正常进入 active
                comboState_ = "active"
                comboActiveTimer_ = getComboDuration()
                comboTickTimer_ = 0
                comboFovElapsed_ = 0
                comboWindSrc_ = playComboSound("comboSndWind_", "audio/sfx/combo_wind.ogg", 0.5, true)
                return
            end

            -- ── 非多段冲刺 → 进入 ACTIVE ──
            comboState_ = "active"
            comboActiveTimer_ = getComboDuration()
            comboTickTimer_ = 0
            comboFovElapsed_ = 0

            -- ── 按类型触发效果（含觉醒强化） ──
            if comboType_ == "sword_path" then
                local cfg = GameConfig.Player.ComboSwordPath
                if EnemyManager and EnemyManager.FreezeEnemiesInRect then
                    EnemyManager.FreezeEnemiesInRect(
                        comboOrigin_, comboForward_,
                        cfg.SlashLength, cfg.SlashWidth * 0.5,
                        cfg.FreezeDuration)
                end
                if WeaponSystem and WeaponSystem.CreateSwordPath then
                    WeaponSystem.CreateSwordPath(
                        comboOrigin_, comboForward_,
                        cfg.SlashLength, cfg.SlashWidth,
                        cfg.SlashDuration)
                end

            elseif comboType_ == "ice_sweep" then
                local cfg = GameConfig.Player.ComboIceSweep
                -- 觉醒强化：lv2+ 范围和持续时间翻倍，lv4+ 再翻倍
                local radiusMul = (awkLv >= 2) and 2.0 or 1.0
                local durMul    = (awkLv >= 2) and 2.0 or 1.0
                if awkLv >= 4 then durMul = durMul * 2.0 end  -- lv4+: 持续时间再翻倍
                local effRadius = cfg.Radius * radiusMul
                local effDur    = cfg.Duration * durMul
                if EnemyManager then
                    EnemyManager.FreezeEnemiesInSemiCircle(
                        comboOrigin_, comboForward_, effRadius, cfg.FreezeDuration)
                    EnemyManager.SlowEnemiesInSemiCircle(
                        comboOrigin_, comboForward_, effRadius, cfg.SlowDuration)
                end
                if WeaponSystem and WeaponSystem.CreateSweepEffect then
                    WeaponSystem.CreateSweepEffect(
                        comboOrigin_, comboForward_, effRadius,
                        effDur, "ice")
                end
                -- 觉醒 lv3+：随机冰锥
                if awkLv >= 3 and EnemyManager then
                    local spikeCount = 8
                    for i = 1, spikeCount do
                        local angle = math.random() * math.pi * 2
                        local dist  = math.random() * effRadius * 0.8
                        local sx = comboOrigin_.x + math.cos(angle) * dist
                        local sz = comboOrigin_.z + math.sin(angle) * dist
                        local spikePos = Vector3(sx, comboOrigin_.y, sz)
                        if EnemyManager.CircleDamage then
                            EnemyManager.CircleDamage(spikePos, 3.0, cfg.Damage * 5)
                        end
                        if WeaponSystem and WeaponSystem.CreateSweepEffect then
                            WeaponSystem.CreateSweepEffect(
                                spikePos, comboForward_, 3.0, effDur * 0.5, "ice")
                        end
                    end
                end
                -- 觉醒4+：首次释放回满体力
                if awkLv >= 4 and not iceFireStaminaRestored_ then
                    dashStamina_ = GameConfig.Player.DashStaminaMax
                    iceFireStaminaRestored_ = true
                end
                comboActiveTimer_ = effDur
                iceActiveTimer_ = effDur  -- 记录冰封生效时间，用于叠加检测
                -- 觉醒4+：检测冰火叠加
                if awkLv >= 4 and fireActiveTimer_ > 0 and not iceFireExplosionDone_ then
                    iceFireExplosionDone_ = true
                    local knockDist = (awkLv >= 5) and 30.0 or 20.0
                    local explosionCount = (awkLv >= 5) and 3 or 1
                    for wave = 1, explosionCount do
                        -- 延迟爆炸效果（用伤害模拟多波）
                        local waveDmg = 500 + wave * 200
                        if EnemyManager and EnemyManager.GlobalKnockback then
                            EnemyManager.GlobalKnockback(comboOrigin_, knockDist, waveDmg)
                        end
                        -- 全图冰火叠加持续伤害
                        if EnemyManager and EnemyManager.GlobalDamage then
                            EnemyManager.GlobalDamage(waveDmg)
                        end
                    end
                    -- 爆炸冲击波特效
                    if WeaponSystem and WeaponSystem.CreateExplosionWaveEffect then
                        WeaponSystem.CreateExplosionWaveEffect(comboOrigin_, 50.0, 2.0, "ice_fire")
                    end
                end

            elseif comboType_ == "fire_sweep" then
                local cfg = GameConfig.Player.ComboFireSweep
                -- 觉醒强化：lv2+ 范围和持续时间翻倍
                local radiusMul = (awkLv >= 2) and 2.0 or 1.0
                local durMul    = (awkLv >= 2) and 2.0 or 1.0
                -- 觉醒 lv4+：持续时间再翻倍（总计 ×4）
                if awkLv >= 4 then durMul = durMul * 2.0 end
                local effRadius = cfg.Radius * radiusMul
                local effDur    = cfg.Duration * durMul
                if EnemyManager then
                    EnemyManager.FreezeEnemiesInSemiCircle(
                        comboOrigin_, comboForward_, effRadius, cfg.FreezeDuration)
                    EnemyManager.BurnEnemiesInSemiCircle(
                        comboOrigin_, comboForward_, effRadius,
                        cfg.BurnDPS, cfg.BurnDuration)
                end
                if WeaponSystem and WeaponSystem.CreateSweepEffect then
                    WeaponSystem.CreateSweepEffect(
                        comboOrigin_, comboForward_, effRadius,
                        effDur, "fire")
                end
                -- 觉醒 lv3：随机火柱
                if awkLv >= 3 and EnemyManager then
                    local pillarCount = 8
                    for i = 1, pillarCount do
                        local angle = math.random() * math.pi * 2
                        local dist  = math.random() * effRadius * 0.8
                        local px = comboOrigin_.x + math.cos(angle) * dist
                        local pz = comboOrigin_.z + math.sin(angle) * dist
                        local pillarPos = Vector3(px, comboOrigin_.y, pz)
                        if EnemyManager.CircleDamage then
                            EnemyManager.CircleDamage(pillarPos, 3.0, cfg.Damage * 5)
                        end
                        if WeaponSystem and WeaponSystem.CreateSweepEffect then
                            WeaponSystem.CreateSweepEffect(
                                pillarPos, comboForward_, 3.0, effDur * 0.5, "fire")
                        end
                    end
                end
                -- 觉醒 lv4+：首次释放回满体力
                if awkLv >= 4 and not iceFireStaminaRestored_ then
                    iceFireStaminaRestored_ = true
                    dashStamina_ = GameConfig.Player.DashStaminaMax
                end
                -- 记录烈焰横扫激活计时器
                fireActiveTimer_ = effDur
                -- 觉醒 lv4+：冰+火叠加 → 全图爆炸冲击波
                if awkLv >= 4 and iceActiveTimer_ > 0 and not iceFireExplosionDone_ then
                    iceFireExplosionDone_ = true
                    local knockDist = (awkLv >= 5) and 30.0 or 20.0
                    local explosionCount = (awkLv >= 5) and 3 or 1
                    for wave = 1, explosionCount do
                        local waveDmg = 500 + wave * 200
                        if EnemyManager and EnemyManager.GlobalKnockback then
                            EnemyManager.GlobalKnockback(comboOrigin_, knockDist, waveDmg)
                        end
                        if EnemyManager and EnemyManager.GlobalDamage then
                            EnemyManager.GlobalDamage(waveDmg)
                        end
                    end
                    if WeaponSystem and WeaponSystem.CreateExplosionWaveEffect then
                        WeaponSystem.CreateExplosionWaveEffect(comboOrigin_, 50.0, 2.0, "ice_fire")
                    end
                end
                comboActiveTimer_ = effDur

            elseif comboType_ == "wind_release" then
                local cfg = GameConfig.Player.ComboWindRelease
                if awkLv >= 5 then
                    -- 觉醒 lv5：全图所有敌人瞬间击飞到30米并加速掉落秒杀
                    if EnemyManager and EnemyManager.GlobalLaunch then
                        EnemyManager.GlobalLaunch(30.0, 99999, true)
                    end
                    if WeaponSystem and WeaponSystem.CreateExplosionWaveEffect then
                        WeaponSystem.CreateExplosionWaveEffect(comboOrigin_, 80.0, 2.5, "wind")
                    end
                    comboActiveTimer_ = 3.0
                elseif awkLv >= 2 then
                    -- 觉醒 lv2+：持续悬浮（非抛物线）
                    local liftDur = 10.0
                    -- lv4+：风柱持续时间再 ×2
                    if awkLv >= 4 then liftDur = liftDur * 2.0 end
                    local fallDmg = cfg.FallDamage
                    -- lv4+：高度提升至30米，坠落伤害大幅增加
                    local liftHeight = cfg.LaunchHeight
                    if awkLv >= 4 then
                        liftHeight = 30.0
                        fallDmg = fallDmg * 5
                    end
                    windPillars_ = {}
                    if awkLv >= 3 then
                        -- lv3+：5 个风柱，均匀扩散分布，不重叠
                        local pillarCount = 5
                        local baseAngleStep = math.pi * 2 / pillarCount  -- 72° 均分
                        local minDist = 15    -- 最小离中心距离
                        local maxDist = 35    -- 最大离中心距离
                        -- lv4+：风柱向外扩散更远
                        if awkLv >= 4 then
                            minDist = 10
                            maxDist = 50
                        end
                        local angleJitter = baseAngleStep * 0.3  -- ±约 22° 随机偏移
                        for i = 1, pillarCount do
                            local baseAngle = (i - 1) * baseAngleStep
                            local angle = baseAngle + (math.random() - 0.5) * 2 * angleJitter
                            local dist  = minDist + math.random() * (maxDist - minDist)
                            local cx = comboOrigin_.x + math.cos(angle) * dist
                            local cz = comboOrigin_.z + math.sin(angle) * dist
                            local pillarCenter = Vector3(cx, comboOrigin_.y, cz)
                            local pillarR = cfg.Radius
                            -- lv4+：风柱半径增大
                            if awkLv >= 4 then pillarR = pillarR * 1.5 end
                            table.insert(windPillars_, {
                                center = pillarCenter,
                                radius = pillarR,
                                height = liftHeight,
                                timer  = liftDur,
                                fallDmg = fallDmg,
                            })
                            if EnemyManager and EnemyManager.SustainLiftInCircle then
                                EnemyManager.SustainLiftInCircle(
                                    pillarCenter, pillarR,
                                    liftHeight, liftDur, fallDmg)
                            end
                            if WeaponSystem and WeaponSystem.CreateWindEffect then
                                WeaponSystem.CreateWindEffect(
                                    pillarCenter, pillarR, liftDur)
                            end
                        end
                    else
                        -- lv2：全圆区域，高 20 米，敌人持续升空直到技能结束坠落
                        local tallHeight = 20.0
                        table.insert(windPillars_, {
                            center = comboOrigin_,
                            radius = cfg.Radius,
                            height = tallHeight,
                            timer  = liftDur,
                            fallDmg = fallDmg,
                        })
                        if EnemyManager and EnemyManager.SustainLiftInCircle then
                            EnemyManager.SustainLiftInCircle(
                                comboOrigin_, cfg.Radius,
                                tallHeight, liftDur, fallDmg)
                        end
                        if WeaponSystem and WeaponSystem.CreateTallWindEffect then
                            WeaponSystem.CreateTallWindEffect(
                                comboOrigin_, cfg.Radius, tallHeight, liftDur)
                        end
                    end
                    comboActiveTimer_ = liftDur
                else
                    -- lv1：原始抛物线击飞
                    if EnemyManager and EnemyManager.LaunchEnemiesInCircle then
                        EnemyManager.LaunchEnemiesInCircle(
                            comboOrigin_, cfg.Radius,
                            cfg.LaunchHeight, cfg.FallDamage)
                    end
                    if WeaponSystem and WeaponSystem.CreateWindEffect then
                        WeaponSystem.CreateWindEffect(
                            comboOrigin_, cfg.Radius, cfg.Duration)
                    end
                end
            end

            -- 播放刀风循环音效
            comboWindSrc_ = playComboSound("comboSndWind_", "audio/sfx/combo_wind.ogg", 0.5, true)
        end
        return
    end

    -- === ACTIVE（按类型分伤害模式） ===
    if comboState_ == "active" then
        comboActiveTimer_ = comboActiveTimer_ - dt
        comboTickTimer_ = comboTickTimer_ + dt
        comboFovElapsed_ = comboFovElapsed_ + dt

        -- FOV 在前 0.5 秒内从最大值回落到正常（视角特效不超过 0.5 秒）
        local fovRecoverTime = 0.5
        local elapsed = comboFovElapsed_  -- 独立计时，不受 tick 重置影响
        if elapsed < fovRecoverTime then
            comboFovBoost_ = COMBO_FOV_MAX_BOOST * (1 - elapsed / fovRecoverTime)
        else
            comboFovBoost_ = 0
        end
        local cam = cameraNode_:GetComponent("Camera")
        if cam then cam.fov = GameConfig.Camera.FOV + comboFovBoost_ end

        -- === lv5 剑道空中俯冲处理 ===
        if comboAirDive_ and comboType_ == "sword_path" then
            comboAirDiveTimer_ = comboAirDiveTimer_ + dt
            if comboAirDiveTimer_ < 0.3 then
                -- 前 0.3 秒：短暂滞空蓄力
            else
                -- 极速下坠
                local diveSpeed = 80.0  -- 80 m/s 极速冲击
                local pos = playerNode_.position
                local newY = pos.y - diveSpeed * dt
                -- 检测是否落地（回到俯冲起始高度或更低）
                local groundY = comboAirDiveOrigin_ and comboAirDiveOrigin_.y or 0
                if newY <= groundY then
                    newY = groundY
                    -- 落地！创建剑波全图清场
                    comboAirDive_ = false
                    playerNode_.position = Vector3(pos.x, newY, pos.z)
                    ensureComboDeps()
                    -- 全图伤害 + 剑波特效
                    if EnemyManager and EnemyManager.GlobalDamage then
                        EnemyManager.GlobalDamage(99999)  -- 秒杀全图
                    end
                    if EnemyManager and EnemyManager.GlobalKnockback then
                        EnemyManager.GlobalKnockback(
                            Vector3(pos.x, newY, pos.z), 40.0, 2000)
                    end
                    if WeaponSystem and WeaponSystem.CreateSwordWaveEffect then
                        WeaponSystem.CreateSwordWaveEffect(
                            Vector3(pos.x, newY, pos.z), 12, 60.0, 2.0)
                    end
                    if WeaponSystem and WeaponSystem.CreateExplosionWaveEffect then
                        WeaponSystem.CreateExplosionWaveEffect(
                            Vector3(pos.x, newY, pos.z), 60.0, 2.5, "sword")
                    end
                    comboActiveTimer_ = 0.5  -- 短暂的落地恢复
                else
                    playerNode_.position = Vector3(pos.x, newY, pos.z)
                end
            end
            -- 俯冲中跳过普通 tick 伤害
            if comboAirDive_ then
                -- 冰火计时器仍需倒计时
                if iceActiveTimer_ > 0 then iceActiveTimer_ = iceActiveTimer_ - dt end
                if fireActiveTimer_ > 0 then fireActiveTimer_ = fireActiveTimer_ - dt end
                if comboActiveTimer_ <= 0 then
                    comboAirDive_ = false
                end
                return
            end
        end

        -- 周期性伤害（wind_release 无持续 tick，只有掉落伤害）
        if comboType_ ~= "wind_release" then
            ensureComboDeps()
            local awkLv = AwakeningSystem and AwakeningSystem.GetLevel() or 0
            local tickRate, tickDmg
            if comboType_ == "sword_path" then
                local cfg = GameConfig.Player.ComboSwordPath
                tickRate = cfg.SlashTickRate
                -- 觉醒剑道伤害倍率：lv1 额外伤害(2x)，lv2+ 巨额伤害(3x)
                local dmgMul = 1.0
                if awkLv >= 2 then
                    dmgMul = 3.0   -- lv2/lv3：巨额伤害
                elseif awkLv >= 1 then
                    dmgMul = 2.0   -- lv1：额外伤害
                end
                tickDmg = cfg.SlashDamage * dmgMul
            elseif comboType_ == "ice_sweep" then
                local cfg = GameConfig.Player.ComboIceSweep
                tickRate = cfg.TickRate
                tickDmg  = cfg.Damage
            elseif comboType_ == "fire_sweep" then
                local cfg = GameConfig.Player.ComboFireSweep
                tickRate = cfg.TickRate
                tickDmg  = cfg.Damage
            end

            if comboTickTimer_ >= tickRate then
                comboTickTimer_ = comboTickTimer_ - tickRate
                if comboType_ == "sword_path" then
                    local cfg = GameConfig.Player.ComboSwordPath
                    if EnemyManager and EnemyManager.RectDamage then
                        EnemyManager.RectDamage(
                            comboOrigin_, comboForward_,
                            cfg.SlashLength, cfg.SlashWidth * 0.5,
                            tickDmg)
                    end
                else
                    -- ice / fire: 半圆区域伤害（觉醒后使用加大的范围）
                    local baseCfg = getComboConfig()
                    local radiusMul = (awkLv >= 2) and 2.0 or 1.0
                    local effRadius = baseCfg.Radius * radiusMul
                    if EnemyManager and EnemyManager.SemiCircleDamage then
                        EnemyManager.SemiCircleDamage(
                            comboOrigin_, comboForward_, effRadius, tickDmg)
                    end
                end
                playComboSound("comboSndSlashHit_", "audio/sfx/combo_slash_hit.ogg", 0.6, false)
            end
        else
            -- wind_release 觉醒 lv2+：持续检测风柱区域，新进入的敌人也升空
            if #windPillars_ > 0 then
                ensureComboDeps()
                for _, wp in ipairs(windPillars_) do
                    wp.timer = wp.timer - dt
                    if wp.timer > 0 and EnemyManager then
                        -- 每帧检测新敌人进入风柱范围
                        local allEnemies = EnemyManager.GetAllEnemies()
                        if allEnemies then
                            for eid, e in pairs(allEnemies) do
                                if e.node and (not e.liftTimer or e.liftTimer <= 0) then
                                    local dx = e.node.position.x - wp.center.x
                                    local dz = e.node.position.z - wp.center.z
                                    local distSq = dx * dx + dz * dz
                                    if distSq <= wp.radius * wp.radius then
                                        -- 半圆形风柱需要额外检测朝向
                                        local inRange = true
                                        if wp.isSemiCircle and wp.forward then
                                            local dot = dx * wp.forward.x + dz * wp.forward.z
                                            inRange = (dot > 0)
                                        end
                                        if inRange then
                                            EnemyManager.LiftSingleEnemy(
                                                eid, wp.height, wp.timer, wp.fallDmg)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- 冰火激活计时器倒计时
        if iceActiveTimer_ > 0 then iceActiveTimer_ = iceActiveTimer_ - dt end
        if fireActiveTimer_ > 0 then fireActiveTimer_ = fireActiveTimer_ - dt end

        -- 结束
        if comboActiveTimer_ <= 0 then
            comboState_ = "idle"
            comboActiveTimer_ = 0
            comboTickTimer_ = 0
            comboFovElapsed_ = 0
            comboFovBoost_ = 0
            comboOrigin_ = nil
            comboForward_ = nil
            windPillars_ = {}
            comboDashTotal_ = 1
            comboDashIndex_ = 0
            -- 重置觉醒 lv4/5 状态
            giantSwordActive_ = false
            giantSwordNode_ = nil
            iceActiveTimer_ = 0
            fireActiveTimer_ = 0
            iceFireStaminaRestored_ = false
            iceFireExplosionDone_ = false
            comboAirDive_ = false
            comboAirDiveTimer_ = 0
            comboAirDiveOrigin_ = nil
            if cam then cam.fov = GameConfig.Camera.FOV end
            if comboWindSrc_ then comboWindSrc_:Stop(); comboWindSrc_ = nil end
        end
        return
    end
end

-- ============================================================================
-- 鼠标模式切换
-- ============================================================================

function FirstPersonController.SetMouseAbsolute()
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true
    -- 切换时清除平滑残余，防止恢复时残留值导致跳动
    smoothYaw_ = 0
    smoothPitch_ = 0
end

function FirstPersonController.SetMouseRelative()
    input.mouseMode = MM_RELATIVE
    input.mouseVisible = false
    -- 跳过接下来 2 帧鼠标输入，丢弃切换瞬间的巨大位移增量
    skipMouseFrames_ = 2
    smoothYaw_ = 0
    smoothPitch_ = 0
end

-- ============================================================================
-- 外部输入接口（触控/摇杆注入）
-- ============================================================================

function FirstPersonController.AddLookDelta(deltaYaw, deltaPitch)
    externalYaw_ = externalYaw_ + deltaYaw
    externalPitch_ = externalPitch_ + deltaPitch
end

function FirstPersonController.SetJoystickInput(x, z)
    joystickX_ = x
    joystickZ_ = z
end

function FirstPersonController.SetSprint(sprinting)
    externalSprint_ = sprinting
end

function FirstPersonController.SetJump(jumping)
    externalJump_ = jumping
end

--- 配置更新（编辑器调参后调用，将 GameConfig 最新值同步到运行时组件）
function FirstPersonController.ApplyConfig()
    if not character_ then return end

    -- 重新读取基础速度（cm/s → m/s）
    baseWalkSpeed_ = GameConfig.Player.MoveSpeed / 100
    baseRunSpeed_ = GameConfig.Player.MoveSpeed / 100 * GameConfig.Player.SprintMultiplier

    -- 强制下一帧更新最终速度（含 speedMult_ 和 slowMult 倍率）
    cachedSlowMult_ = -1.0

    -- 同步物理参数到 KCC 和 RigidBody
    local kcc = playerNode_:GetComponent("KinematicCharacterController")
    if kcc then
        kcc:SetJumpSpeed(GameConfig.Player.JumpSpeed)
        kcc:SetGravity(Vector3(0, GameConfig.Player.Gravity, 0))
        kcc:SetLinearDamping(GameConfig.Player.LinearDamping)
    end

    local rb = playerNode_:GetComponent("RigidBody")
    if rb then
        rb.mass = GameConfig.Player.Mass
        rb.linearDamping = GameConfig.Player.LinearDamping
    end

    -- 同步视点高度
    if cameraNode_ then
        cameraNode_.position = Vector3(0, GameConfig.Player.EyeHeight, 0)
    end
end

-- ============================================================================
-- 闪现体力查询接口（供 HUD 使用）
-- ============================================================================

--- 获取当前闪现体力 (0~Max)
function FirstPersonController.GetDashStamina()
    return dashStamina_
end

--- 获取当前可用闪现次数
function FirstPersonController.GetDashCharges()
    local cost = GameConfig.Player.DashStaminaCost
    if cost <= 0 then return 0 end
    return math.floor(dashStamina_ / cost)
end

--- 获取最大闪现次数
function FirstPersonController.GetDashMaxCharges()
    return GameConfig.Player.DashMaxCharges
end

--- 获取闪现体力百分比 (0~1)
function FirstPersonController.GetDashStaminaPct()
    local maxSt = GameConfig.Player.DashStaminaMax
    if maxSt <= 0 then return 0 end
    return dashStamina_ / maxSt
end

--- 屏幕线条特效进度 (0=无, >0=进行中, 值为 0~1 的归一化进度)
function FirstPersonController.GetDashLinesFx()
    if dashLinesTimer_ <= 0 then return 0 end
    return dashLinesTimer_ / DASH_LINES_DURATION
end

--- 本帧是否刚触发闪现
function FirstPersonController.DashJustFired()
    return dashJustFired_
end

--- 闪现无敌帧是否激活
function FirstPersonController.IsDashInvincible()
    return dashInvTimer_ > 0
end

--- 闪现无敌帧剩余进度 (0~1, 1=刚触发, 0=结束)
function FirstPersonController.GetDashInvPct()
    local dur = GameConfig.Player.DashInvDuration
    if dur <= 0 or dashInvTimer_ <= 0 then return 0 end
    return dashInvTimer_ / dur
end

-- ============================================================================
-- 剑道组合技查询接口（供 HUD / main.lua 使用）
-- ============================================================================

--- 获取组合技状态 ("idle"/"charging"/"rushing"/"active")
function FirstPersonController.GetComboState()
    return comboState_
end

--- 获取蓄力进度 (0~1)
function FirstPersonController.GetComboChargePct()
    if comboState_ ~= "charging" then return 0 end
    return math.min(1, comboChargeTimer_ / GameConfig.Player.ComboChargeTime)
end

--- 获取冲击闪白进度 (0~1, 1=刚闪, 0=消失)
function FirstPersonController.GetComboRushFlash()
    return comboRushFlash_
end

--- 获取剑道激活剩余进度 (0~1, 1=刚开始, 0=结束)
function FirstPersonController.GetComboActivePct()
    if comboState_ ~= "active" then return 0 end
    return comboActiveTimer_ / getComboDuration()
end

--- 获取当前组合技类型 ("sword_path"/"ice_sweep"/"fire_sweep"/"wind_release")
function FirstPersonController.GetComboType()
    return comboType_
end

--- 获取冲刺进度 (0~1, 0=刚开始, 1=结束)
function FirstPersonController.GetComboRushPct()
    if comboState_ ~= "rushing" then return 0 end
    return math.min(1, comboRushTimer_ / COMBO_RUSH_DURATION)
end

--- 冲刺是否刚触发（本帧，用于生成线条）
function FirstPersonController.ComboRushJustFired()
    return comboRushJustFired_
end

return FirstPersonController
