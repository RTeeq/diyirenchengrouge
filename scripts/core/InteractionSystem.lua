-- ============================================================================
-- InteractionSystem.lua — 射线交互系统
-- 从相机发射射线检测可交互物体（NPC/物品/门/告示牌等）
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local MobileControls = require("ui.MobileControls")
local GamepadControls = require("ui.GamepadControls")

local InteractionSystem = {}

---@type PhysicsWorld
local physicsWorld_ = nil
---@type Node
local cameraNode_ = nil

-- 当前注视的可交互物体
local currentTarget_ = nil
local currentTargetType_ = nil  -- "npc" | "item" | "door" | "sign" | "examine"

-- 回调
local onTargetChanged_ = nil   -- function(target, targetType)
local onInteract_ = nil        -- function(target, targetType)

-- ============================================================================
-- 初始化
-- ============================================================================

---@param scene Scene
---@param camNode Node
function InteractionSystem.Init(scene, camNode)
    physicsWorld_ = scene:GetComponent("PhysicsWorld")
    cameraNode_ = camNode
    currentTarget_ = nil
    currentTargetType_ = nil
    print("[InteractionSystem] 初始化完成")
end

--- 设置目标变化回调
---@param callback function(target: Node|nil, targetType: string|nil)
function InteractionSystem.OnTargetChanged(callback)
    onTargetChanged_ = callback
end

--- 设置交互回调
---@param callback function(target: Node, targetType: string)
function InteractionSystem.OnInteract(callback)
    onInteract_ = callback
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

---@param dt number
function InteractionSystem.Update(dt)
    if not physicsWorld_ or not cameraNode_ then return end

    -- 从相机正前方发射射线
    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return end

    local ray = camera:GetScreenRay(0.5, 0.5)
    local maxDist = GameConfig.Player.InteractDistance
    local result = physicsWorld_:RaycastSingle(ray, maxDist)

    local newTarget = nil
    local newType = nil

    if result.body ~= nil then
        local hitNode = result.body:GetNode()
        -- 查找可交互标记（向上遍历节点树最多3层）
        local node = hitNode
        for _ = 1, 3 do
            if node == nil then break end
            local interactType = node:GetVar("InteractType")
            if interactType ~= nil and not interactType:IsEmpty() then
                newTarget = node
                newType = interactType:GetString()
                break
            end
            node = node:GetParent()
        end
    end

    -- 判断目标是否发生变化
    if newTarget ~= currentTarget_ then
        currentTarget_ = newTarget
        currentTargetType_ = newType
        if onTargetChanged_ then
            onTargetChanged_(currentTarget_, currentTargetType_)
        end
    end

    -- 检测按 F 交互 / 移动端交互按钮 / 手柄 B 按钮
    if input:GetKeyPress(KEY_F) or MobileControls.WasPressed("interact") or GamepadControls.WasPressed("interact") then
        if currentTarget_ and currentTargetType_ then
            if onInteract_ then
                onInteract_(currentTarget_, currentTargetType_)
            end
        end
    end
end

-- ============================================================================
-- 查询当前目标
-- ============================================================================

---@return Node|nil
function InteractionSystem.GetCurrentTarget()
    return currentTarget_
end

---@return string|nil
function InteractionSystem.GetCurrentTargetType()
    return currentTargetType_
end

---@return boolean
function InteractionSystem.HasTarget()
    return currentTarget_ ~= nil
end

-- ============================================================================
-- 清除目标（切换状态时调用）
-- ============================================================================

function InteractionSystem.ClearTarget()
    if currentTarget_ then
        currentTarget_ = nil
        currentTargetType_ = nil
        if onTargetChanged_ then
            onTargetChanged_(nil, nil)
        end
    end
end

return InteractionSystem
