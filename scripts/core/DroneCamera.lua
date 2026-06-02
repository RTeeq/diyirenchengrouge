-- ============================================================================
-- DroneCamera.lua — 无人机自由视角相机
-- L 键切换，WASD 移动，QE 升降，Shift 加速，鼠标控制视角
-- ============================================================================

local GameConfig = require("config.GameConfig")

local DroneCamera = {}

---@type Scene
local scene_ = nil
---@type Node
local droneNode_ = nil
---@type Node
local droneCamNode_ = nil
---@type Camera
local droneCamera_ = nil

local active_ = false
local yaw_ = 0.0
local pitch_ = 0.0

-- 无人机参数
local MOVE_SPEED = 15.0        -- 基础移动速度 m/s
local FAST_MULT = 3.0          -- Shift 加速倍率
local MOUSE_SENS = 0.15        -- 鼠标灵敏度
local VERTICAL_SPEED = 10.0    -- Q/E 升降速度

-- 保存切换前的相机引用，以便恢复
local savedFPCamera_ = nil

--- 初始化（只调用一次）
---@param scene Scene
function DroneCamera.Init(scene)
    scene_ = scene

    -- 创建无人机节点（不挂物理）
    droneNode_ = scene_:CreateChild("DroneRoot")
    droneCamNode_ = droneNode_:CreateChild("DroneCamera")

    -- 创建相机
    droneCamera_ = droneCamNode_:CreateComponent("Camera")
    droneCamera_.nearClip = GameConfig.Camera.NearClip
    droneCamera_.farClip = GameConfig.Camera.FarClip
    droneCamera_.fov = GameConfig.Camera.FOV

    droneNode_.enabled = false
end

--- 切换无人机视角
---@param fpController table  第一人称控制器实例
function DroneCamera.Toggle(fpController)
    if not droneNode_ then return end

    if active_ then
        -- 关闭无人机 → 恢复第一人称
        DroneCamera.Deactivate(fpController)
    else
        -- 开启无人机 → 从玩家位置起飞
        DroneCamera.Activate(fpController)
    end
end

--- 激活无人机视角
---@param fpController table
function DroneCamera.Activate(fpController)
    if active_ then return end
    active_ = true

    -- 保存第一人称相机
    savedFPCamera_ = fpController:GetCamera()

    -- 从玩家当前位置和朝向启动无人机
    local camPos = fpController:GetPosition()
    local fpYaw, fpPitch = fpController:GetAngles()
    yaw_ = fpYaw
    pitch_ = fpPitch

    droneNode_.enabled = true
    droneNode_.position = camPos
    droneCamNode_.rotation = Quaternion(pitch_, yaw_, 0)

    -- 切换视口到无人机相机
    local viewport = Viewport:new(scene_, droneCamera_)
    renderer:SetViewport(0, viewport)

    -- 禁用玩家控制器（保持物理体不动）
    fpController:SetEnabled(false)

    print("[DroneCamera] 无人机视角已激活")
end

--- 关闭无人机视角
---@param fpController table
function DroneCamera.Deactivate(fpController)
    if not active_ then return end
    active_ = false

    droneNode_.enabled = false

    -- 恢复第一人称相机视口
    if savedFPCamera_ then
        local viewport = Viewport:new(scene_, savedFPCamera_)
        renderer:SetViewport(0, viewport)
        savedFPCamera_ = nil
    end

    -- 重新启用玩家控制器
    fpController:SetEnabled(true)

    print("[DroneCamera] 已恢复第一人称视角")
end

--- 每帧更新（仅在 active 时调用）
---@param dt number
function DroneCamera.Update(dt)
    if not active_ then return end

    -- 鼠标控制视角
    local mx = input.mouseMoveX
    local my = input.mouseMoveY
    yaw_ = yaw_ + mx * MOUSE_SENS
    pitch_ = pitch_ + my * MOUSE_SENS
    if pitch_ < -89 then pitch_ = -89 end
    if pitch_ > 89 then pitch_ = 89 end

    droneCamNode_.rotation = Quaternion(pitch_, yaw_, 0)

    -- 计算移动方向（世界空间）
    local speed = MOVE_SPEED
    if input:GetKeyDown(KEY_SHIFT) then
        speed = speed * FAST_MULT
    end

    -- 前方/右方向量（基于 yaw，忽略 pitch 做水平移动）
    local yawRad = yaw_ * math.pi / 180
    local fwdX = math.sin(yawRad)
    local fwdZ = math.cos(yawRad)
    local rightX = math.cos(yawRad)
    local rightZ = -math.sin(yawRad)

    local moveX, moveY, moveZ = 0, 0, 0

    -- WASD 水平移动
    if input:GetKeyDown(KEY_W) then
        moveX = moveX + fwdX
        moveZ = moveZ + fwdZ
    end
    if input:GetKeyDown(KEY_S) then
        moveX = moveX - fwdX
        moveZ = moveZ - fwdZ
    end
    if input:GetKeyDown(KEY_D) then
        moveX = moveX + rightX
        moveZ = moveZ + rightZ
    end
    if input:GetKeyDown(KEY_A) then
        moveX = moveX - rightX
        moveZ = moveZ - rightZ
    end

    -- QE / Space/Ctrl 升降
    if input:GetKeyDown(KEY_E) or input:GetKeyDown(KEY_SPACE) then
        moveY = moveY + 1
    end
    if input:GetKeyDown(KEY_Q) or input:GetKeyDown(KEY_CTRL) then
        moveY = moveY - 1
    end

    -- 归一化水平方向
    local hLen = math.sqrt(moveX * moveX + moveZ * moveZ)
    if hLen > 0.001 then
        moveX = moveX / hLen
        moveZ = moveZ / hLen
    end

    -- 应用移动
    local pos = droneNode_.position
    droneNode_.position = Vector3(
        pos.x + moveX * speed * dt,
        pos.y + moveY * VERTICAL_SPEED * dt,
        pos.z + moveZ * speed * dt
    )
end

--- 是否处于无人机模式
---@return boolean
function DroneCamera.IsActive()
    return active_
end

return DroneCamera
