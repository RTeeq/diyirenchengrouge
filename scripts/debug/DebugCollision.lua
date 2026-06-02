-- ============================================================================
-- DebugCollision.lua — 碰撞体可视化调试工具
-- 扫描场景中所有 CollisionShape，为每个碰撞体创建匹配的半透明网格
-- 初始完全透明，通过开发者面板切换显示红色半透明材质
-- ============================================================================

local GameConfig = require("config.GameConfig")

local DebugCollision = {}

---@type Scene
local scene_ = nil
local debugNodes_ = {}       -- { node = Node }[]
local visible_ = false       -- 当前是否可见
local matVisible_ = nil      -- 红色半透明材质（可见时）
local matHidden_  = nil      -- 完全透明材质（隐藏时）

-- ============================================================================
-- 材质
-- ============================================================================

local function createDebugMaterials()
    -- 红色半透明（可见状态）
    matVisible_ = Material:new()
    matVisible_:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    matVisible_:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.1, 0.1, 0.3)))
    matVisible_:SetShaderParameter("Roughness", Variant(0.9))
    matVisible_:SetShaderParameter("Metallic", Variant(0.0))

    -- 完全透明（隐藏状态）
    matHidden_ = Material:new()
    matHidden_:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    matHidden_:SetShaderParameter("MatDiffColor", Variant(Color(0.0, 0.0, 0.0, 0.0)))
    matHidden_:SetShaderParameter("Roughness", Variant(0.9))
    matHidden_:SetShaderParameter("Metallic", Variant(0.0))
end

-- ============================================================================
-- 为单个 CollisionShape 创建可视化节点
-- ============================================================================

--- 为碰撞体创建匹配的可视化子节点
---@param parentNode Node 碰撞体所在节点
---@param shape CollisionShape
---@return Node|nil
local function createVisualForShape(parentNode, shape)
    local shapeType = shape.shapeType
    local size = shape.size           -- Vector3
    local offset = shape.position     -- Vector3（碰撞体偏移）
    local rot = shape.rotation        -- Quaternion

    local debugNode = parentNode:CreateChild("__debug_collision__")
    debugNode.position = offset
    debugNode.rotation = rot

    local mdl = debugNode:CreateComponent("StaticModel")
    local mat = visible_ and matVisible_ or matHidden_

    if shapeType == SHAPE_BOX then
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        -- Box.mdl 原始尺寸 1×1×1，直接缩放到碰撞体 size
        debugNode.scale = size
        mdl:SetMaterial(mat)

    elseif shapeType == SHAPE_SPHERE then
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        -- Sphere.mdl 直径 1.0，size.x = 直径
        local d = size.x
        debugNode.scale = Vector3(d, d, d)
        mdl:SetMaterial(mat)

    elseif shapeType == SHAPE_CAPSULE then
        -- 用 Cylinder 近似胶囊体
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        -- Cylinder.mdl 高度 1.0，直径 1.0
        -- size.x = 直径, size.y = 总高度
        local d = size.x
        local h = size.y
        debugNode.scale = Vector3(d, h, d)
        mdl:SetMaterial(mat)

    elseif shapeType == SHAPE_CYLINDER then
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local d = size.x
        local h = size.y
        debugNode.scale = Vector3(d, h, d)
        mdl:SetMaterial(mat)

    elseif shapeType == SHAPE_CONE then
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        local d = size.x
        local h = size.y
        debugNode.scale = Vector3(d, h, d)
        mdl:SetMaterial(mat)

    else
        -- TriangleMesh / ConvexHull / Terrain / StaticPlane
        -- 使用 worldBoundingBox 的 AABB 近似
        local wbb = shape.worldBoundingBox
        if wbb then
            local bbSize = wbb.size
            if bbSize and bbSize.x > 0 and bbSize.y > 0 and bbSize.z > 0 then
                mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
                -- 需要在世界空间放置，转换为父节点本地空间
                local center = wbb.center
                if center then
                    local localCenter = parentNode:WorldToLocal(center)
                    debugNode.position = localCenter
                end
                -- 考虑父节点的缩放
                local parentScale = parentNode.worldScale
                debugNode.scale = Vector3(
                    bbSize.x / parentScale.x,
                    bbSize.y / parentScale.y,
                    bbSize.z / parentScale.z
                )
                mdl:SetMaterial(mat)
            else
                debugNode:Remove()
                return nil
            end
        else
            debugNode:Remove()
            return nil
        end
    end

    return debugNode
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 初始化：扫描场景中所有碰撞体并创建可视化节点
---@param scene Scene
function DebugCollision.Init(scene)
    scene_ = scene
    DebugCollision.Clear()
    createDebugMaterials()
    DebugCollision.Scan()
    print("[DebugCollision] 初始化完成, 碰撞体数量: " .. #debugNodes_)
end

--- 扫描场景，为所有 CollisionShape 创建可视化节点
function DebugCollision.Scan()
    if not scene_ then return end

    -- 清理旧的
    DebugCollision.Clear()
    createDebugMaterials()

    -- 查找所有带 CollisionShape 的节点
    local nodes = scene_:GetChildrenWithComponent("CollisionShape", true)
    if not nodes then return end

    for i = 1, #nodes do
        local node = nodes[i]
        -- 获取该节点上的 CollisionShape（可能多个，但通常一个）
        local shape = node:GetComponent("CollisionShape")
        if shape then
            local debugNode = createVisualForShape(node, shape)
            if debugNode then
                table.insert(debugNodes_, { node = debugNode })
            end
        end
    end

    print("[DebugCollision] 扫描完成, 创建 " .. #debugNodes_ .. " 个可视化碰撞体")
end

--- 切换碰撞体可视化开关
---@return boolean 切换后的状态
function DebugCollision.Toggle()
    visible_ = not visible_
    local mat = visible_ and matVisible_ or matHidden_

    for _, entry in ipairs(debugNodes_) do
        if entry.node then
            local mdl = entry.node:GetComponent("StaticModel")
            if mdl then
                mdl:SetMaterial(mat)
            end
        end
    end

    print("[DebugCollision] 碰撞体可视化: " .. (visible_ and "开启" or "关闭"))
    return visible_
end

--- 设置碰撞体可视化状态
---@param show boolean
function DebugCollision.SetVisible(show)
    if show == visible_ then return end
    DebugCollision.Toggle()
end

--- 获取当前可视化状态
---@return boolean
function DebugCollision.IsVisible()
    return visible_
end

--- 获取碰撞体数量
---@return number
function DebugCollision.GetCount()
    return #debugNodes_
end

--- 清理所有可视化节点
function DebugCollision.Clear()
    for _, entry in ipairs(debugNodes_) do
        if entry.node then
            entry.node:Remove()
        end
    end
    debugNodes_ = {}
    visible_ = false
end

return DebugCollision
