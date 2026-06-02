-- ============================================================================
-- NPCManager.lua — NPC管理器（高精度模型版）
-- 创建NPC几何体、配置碰撞体、管理NPC状态
-- ============================================================================

local GameConfig = require("config.GameConfig")

local NPCManager = {}

-- NPC数据存储
local npcNodes_ = {}  -- { [npcId] = node }

-- NPC配色与位置配置（适配环形村庄布局）
local NPC_CONFIGS = {
    [GameConfig.NPCs.AYANG] = {
        name = "阿阳",
        pos = Vector3(17, 0, 10),      -- 阿阳家门前外侧（房子14,6 宽4深5，门朝Z+，门口z=8.5+2）
        bodyColor = Color(0.30, 0.50, 0.75, 1.0),   -- 蓝衣
        beltColor = Color(0.20, 0.35, 0.55, 1.0),   -- 深蓝腰带
        headColor = Color(0.85, 0.72, 0.60, 1.0),   -- 肤色
        hairColor = Color(0.15, 0.12, 0.10, 1.0),   -- 黑发
        eyeColor  = Color(0.10, 0.08, 0.06, 1.0),   -- 深色眼
        shoeColor = Color(0.25, 0.18, 0.12, 1.0),   -- 棕鞋
        accessory = "headband",  -- 头带
        accColor  = Color(0.85, 0.25, 0.15, 1.0),   -- 红色头带
        scale = 1.0,
    },
    [GameConfig.NPCs.QIQI] = {
        name = "七七",
        pos = Vector3(-7, 0, -9),       -- 七七家门前外侧（房子-10,-12 宽3.5深4，门朝Z+，门口z=-10+2）
        bodyColor = Color(0.90, 0.85, 0.95, 1.0),   -- 淡紫衣
        beltColor = Color(0.70, 0.55, 0.80, 1.0),   -- 紫腰带
        headColor = Color(0.88, 0.78, 0.68, 1.0),
        hairColor = Color(0.20, 0.10, 0.25, 1.0),   -- 深紫发
        eyeColor  = Color(0.15, 0.08, 0.20, 1.0),
        shoeColor = Color(0.60, 0.40, 0.55, 1.0),
        accessory = "ribbon",    -- 蝴蝶结
        accColor  = Color(0.95, 0.60, 0.70, 1.0),   -- 粉色蝴蝶结
        scale = 0.88,
    },
    [GameConfig.NPCs.WENGMOLAO] = {
        name = "嗡摩佬",
        pos = Vector3(15, 0, -4),       -- 商店门前外侧（房子12,-8 宽4.5深5，门朝Z+，门口z=-5.5+2）
        bodyColor = Color(0.55, 0.45, 0.30, 1.0),   -- 褐衣
        beltColor = Color(0.40, 0.30, 0.18, 1.0),   -- 暗褐腰带
        headColor = Color(0.78, 0.65, 0.52, 1.0),
        hairColor = Color(0.50, 0.48, 0.45, 1.0),   -- 灰白发
        eyeColor  = Color(0.20, 0.18, 0.15, 1.0),
        shoeColor = Color(0.35, 0.25, 0.15, 1.0),
        accessory = "hat",       -- 草帽
        accColor  = Color(0.75, 0.68, 0.45, 1.0),   -- 草帽色
        scale = 0.95,
    },
    [GameConfig.NPCs.TUDI_SHEN] = {
        name = "山根土地神",
        pos = Vector3(-5, 0, 33),       -- 庙宇前广场（庙宇0,38 深6，前沿z=35，往前留距离）
        bodyColor = Color(0.75, 0.65, 0.40, 1.0),   -- 土金色
        beltColor = Color(0.60, 0.50, 0.25, 1.0),   -- 金腰带
        headColor = Color(0.82, 0.70, 0.55, 1.0),
        hairColor = Color(0.60, 0.55, 0.45, 1.0),   -- 花白发
        eyeColor  = Color(0.25, 0.20, 0.15, 1.0),
        shoeColor = Color(0.45, 0.35, 0.20, 1.0),
        accessory = "beard",     -- 胡须
        accColor  = Color(0.65, 0.60, 0.50, 1.0),   -- 花白胡须
        scale = 0.90,
    },
    [GameConfig.NPCs.CUNZHANG] = {
        name = "村长",
        pos = Vector3(-9, 0, 19),       -- 村长家门前外侧（房子-12,14 宽6深7，门朝Z+，门口z=17.5+2）
        bodyColor = Color(0.40, 0.35, 0.50, 1.0),   -- 深紫衣
        beltColor = Color(0.55, 0.20, 0.20, 1.0),   -- 暗红腰带
        headColor = Color(0.80, 0.68, 0.55, 1.0),
        hairColor = Color(0.35, 0.32, 0.30, 1.0),   -- 深发
        eyeColor  = Color(0.12, 0.10, 0.08, 1.0),
        shoeColor = Color(0.20, 0.15, 0.10, 1.0),
        accessory = "hat",       -- 方巾帽
        accColor  = Color(0.30, 0.25, 0.40, 1.0),   -- 深紫帽
        scale = 1.0,
    },
}

-- ============================================================================
-- 创建高精度NPC模型
-- ============================================================================

---@param parent Node
---@param npcId string
---@param cfg table
---@return Node
local function createNPCModel(parent, npcId, cfg)
    local node = parent:CreateChild("NPC_" .. npcId)
    node.position = cfg.pos

    local s = cfg.scale or 1.0

    local function makeMat(color)
        return GameConfig.CreateMaterial(color)
    end

    -- ====== 腿部（两根圆柱） ======
    local legH = 0.7 * s
    local legR = 0.1 * s
    -- 左腿
    local legL = node:CreateChild("LegL")
    legL.position = Vector3(-0.1 * s, legH / 2, 0)
    legL.scale = Vector3(legR * 2, legH, legR * 2)
    local legLM = legL:CreateComponent("StaticModel")
    legLM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    legLM:SetMaterial(makeMat(cfg.bodyColor))
    legLM.castShadows = true
    -- 右腿
    local legR_ = node:CreateChild("LegR")
    legR_.position = Vector3(0.1 * s, legH / 2, 0)
    legR_.scale = Vector3(legR * 2, legH, legR * 2)
    local legRM = legR_:CreateComponent("StaticModel")
    legRM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    legRM:SetMaterial(makeMat(cfg.bodyColor))
    legRM.castShadows = true

    -- ====== 鞋子（两个扁盒） ======
    local shoeNode = node:CreateChild("ShoeL")
    shoeNode.position = Vector3(-0.1 * s, 0.05 * s, 0.03 * s)
    shoeNode.scale = Vector3(0.14 * s, 0.1 * s, 0.2 * s)
    local shoeM = shoeNode:CreateComponent("StaticModel")
    shoeM:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    shoeM:SetMaterial(makeMat(cfg.shoeColor))
    shoeM.castShadows = true

    local shoeNodeR = node:CreateChild("ShoeR")
    shoeNodeR.position = Vector3(0.1 * s, 0.05 * s, 0.03 * s)
    shoeNodeR.scale = Vector3(0.14 * s, 0.1 * s, 0.2 * s)
    local shoeMR = shoeNodeR:CreateComponent("StaticModel")
    shoeMR:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    shoeMR:SetMaterial(makeMat(cfg.shoeColor))
    shoeMR.castShadows = true

    -- ====== 上身（圆柱） ======
    local torsoH = 0.6 * s
    local torsoNode = node:CreateChild("Torso")
    torsoNode.position = Vector3(0, legH + torsoH / 2, 0)
    torsoNode.scale = Vector3(0.4 * s, torsoH, 0.3 * s)
    local torsoM = torsoNode:CreateComponent("StaticModel")
    torsoM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    torsoM:SetMaterial(makeMat(cfg.bodyColor))
    torsoM.castShadows = true

    -- ====== 腰带 ======
    local beltNode = node:CreateChild("Belt")
    beltNode.position = Vector3(0, legH + 0.02 * s, 0)
    beltNode.scale = Vector3(0.42 * s, 0.06 * s, 0.32 * s)
    local beltM = beltNode:CreateComponent("StaticModel")
    beltM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    beltM:SetMaterial(makeMat(cfg.beltColor))
    beltM.castShadows = true

    -- ====== 手臂（两个小圆柱） ======
    local armH = 0.5 * s
    local armR = 0.06 * s
    local shoulderY = legH + torsoH * 0.8
    -- 左臂
    local armL = node:CreateChild("ArmL")
    armL.position = Vector3(-0.25 * s, shoulderY - armH * 0.3, 0)
    armL.scale = Vector3(armR * 2, armH, armR * 2)
    armL.rotation = Quaternion(10, Vector3.FORWARD)
    local armLM = armL:CreateComponent("StaticModel")
    armLM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    armLM:SetMaterial(makeMat(cfg.bodyColor))
    armLM.castShadows = true
    -- 右臂
    local armR2 = node:CreateChild("ArmR")
    armR2.position = Vector3(0.25 * s, shoulderY - armH * 0.3, 0)
    armR2.scale = Vector3(armR * 2, armH, armR * 2)
    armR2.rotation = Quaternion(-10, Vector3.FORWARD)
    local armRM = armR2:CreateComponent("StaticModel")
    armRM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    armRM:SetMaterial(makeMat(cfg.bodyColor))
    armRM.castShadows = true

    -- ====== 手部（两个小球） ======
    local handY = shoulderY - armH * 0.7
    local handNode = node:CreateChild("HandL")
    handNode.position = Vector3(-0.28 * s, handY, 0)
    handNode.scale = Vector3(0.08 * s, 0.08 * s, 0.08 * s)
    local handM = handNode:CreateComponent("StaticModel")
    handM:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    handM:SetMaterial(makeMat(cfg.headColor))
    handM.castShadows = true

    local handNodeR = node:CreateChild("HandR")
    handNodeR.position = Vector3(0.28 * s, handY, 0)
    handNodeR.scale = Vector3(0.08 * s, 0.08 * s, 0.08 * s)
    local handMR = handNodeR:CreateComponent("StaticModel")
    handMR:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    handMR:SetMaterial(makeMat(cfg.headColor))
    handMR.castShadows = true

    -- ====== 头部（球体） ======
    local headY = legH + torsoH + 0.18 * s
    local headNode = node:CreateChild("Head")
    headNode.position = Vector3(0, headY, 0)
    headNode.scale = Vector3(0.32 * s, 0.32 * s, 0.32 * s)
    local headModel = headNode:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    headModel:SetMaterial(makeMat(cfg.headColor))
    headModel.castShadows = true

    -- ====== 眼睛（两个小球，正面） ======
    local eyeY = headY + 0.03 * s
    local eyeZ = 0.14 * s
    local eyeScale = Vector3(0.05 * s, 0.05 * s, 0.03 * s)

    local eyeL = node:CreateChild("EyeL")
    eyeL.position = Vector3(-0.08 * s, eyeY, eyeZ)
    eyeL.scale = eyeScale
    local eyeLM = eyeL:CreateComponent("StaticModel")
    eyeLM:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    eyeLM:SetMaterial(makeMat(cfg.eyeColor))

    local eyeR = node:CreateChild("EyeR")
    eyeR.position = Vector3(0.08 * s, eyeY, eyeZ)
    eyeR.scale = eyeScale
    local eyeRM = eyeR:CreateComponent("StaticModel")
    eyeRM:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    eyeRM:SetMaterial(makeMat(cfg.eyeColor))

    -- ====== 头发（扁球覆盖头顶+后脑） ======
    local hairNode = node:CreateChild("Hair")
    hairNode.position = Vector3(0, headY + 0.1 * s, -0.04 * s)
    hairNode.scale = Vector3(0.36 * s, 0.2 * s, 0.36 * s)
    local hairModel = hairNode:CreateComponent("StaticModel")
    hairModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    hairModel:SetMaterial(makeMat(cfg.hairColor))
    hairModel.castShadows = true

    -- ====== 配饰 ======
    if cfg.accessory == "headband" then
        -- 头带（额头环形）
        local hb = node:CreateChild("Headband")
        hb.position = Vector3(0, headY + 0.05 * s, 0)
        hb.scale = Vector3(0.35 * s, 0.04 * s, 0.35 * s)
        local hbM = hb:CreateComponent("StaticModel")
        hbM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        hbM:SetMaterial(makeMat(cfg.accColor))
    elseif cfg.accessory == "ribbon" then
        -- 蝴蝶结（头顶两个小球）
        local rb1 = node:CreateChild("Ribbon1")
        rb1.position = Vector3(-0.08 * s, headY + 0.18 * s, -0.05 * s)
        rb1.scale = Vector3(0.1 * s, 0.06 * s, 0.06 * s)
        local rb1M = rb1:CreateComponent("StaticModel")
        rb1M:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        rb1M:SetMaterial(makeMat(cfg.accColor))
        local rb2 = node:CreateChild("Ribbon2")
        rb2.position = Vector3(0.08 * s, headY + 0.18 * s, -0.05 * s)
        rb2.scale = Vector3(0.1 * s, 0.06 * s, 0.06 * s)
        local rb2M = rb2:CreateComponent("StaticModel")
        rb2M:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        rb2M:SetMaterial(makeMat(cfg.accColor))
    elseif cfg.accessory == "hat" then
        -- 帽子（圆柱 + 圆盘）
        local hatTop = node:CreateChild("HatTop")
        hatTop.position = Vector3(0, headY + 0.2 * s, 0)
        hatTop.scale = Vector3(0.28 * s, 0.15 * s, 0.28 * s)
        local hatTopM = hatTop:CreateComponent("StaticModel")
        hatTopM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        hatTopM:SetMaterial(makeMat(cfg.accColor))
        local hatBrim = node:CreateChild("HatBrim")
        hatBrim.position = Vector3(0, headY + 0.14 * s, 0)
        hatBrim.scale = Vector3(0.45 * s, 0.03 * s, 0.45 * s)
        local hatBrimM = hatBrim:CreateComponent("StaticModel")
        hatBrimM:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        hatBrimM:SetMaterial(makeMat(cfg.accColor))
    elseif cfg.accessory == "beard" then
        -- 胡须（下巴小球）
        local beard = node:CreateChild("Beard")
        beard.position = Vector3(0, headY - 0.12 * s, 0.12 * s)
        beard.scale = Vector3(0.15 * s, 0.1 * s, 0.08 * s)
        local beardM = beard:CreateComponent("StaticModel")
        beardM:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        beardM:SetMaterial(makeMat(cfg.accColor))
    end

    -- 设置交互标记
    node:SetVar("InteractType", Variant("npc"))
    node:SetVar("NpcId", Variant(npcId))
    node:SetVar("NpcName", Variant(cfg.name))

    -- 碰撞体（Trigger层：玩家物理体不碰撞，射线检测仍可命中）
    local rb = node:CreateComponent("RigidBody")
    rb.mass = 0
    rb.collisionLayer = CollisionLayerTrigger
    local shape = node:CreateComponent("CollisionShape")
    shape:SetCapsule(0.5 * s, 1.8 * s, Vector3(0, 0.9 * s, 0))

    return node
end

-- ============================================================================
-- 公开接口
-- ============================================================================

---@param scene Scene
function NPCManager.SpawnAll(scene)
    local world = scene:GetChild("Village")
    if not world then
        world = scene:CreateChild("Village")
    end

    -- 清理旧 NPC 节点，防止重复生成叠加
    local oldNPCs = world:GetChild("NPCs")
    if oldNPCs then
        oldNPCs:Remove()
    end
    npcNodes_ = {}

    local npcParent = world:CreateChild("NPCs")

    for npcId, cfg in pairs(NPC_CONFIGS) do
        local node = createNPCModel(npcParent, npcId, cfg)
        npcNodes_[npcId] = node
    end

    print("[NPCManager] 已生成所有NPC（高精度模型）")
end

---@param npcId string
---@return Node|nil
function NPCManager.GetNode(npcId)
    return npcNodes_[npcId]
end

---@return table<string, Node>
function NPCManager.GetAllNodes()
    return npcNodes_
end

---@return table
function NPCManager.GetConfigs()
    return NPC_CONFIGS
end

---@param npcId string
---@param pos Vector3
function NPCManager.UpdateNPCTransform(npcId, pos)
    local node = npcNodes_[npcId]
    if node then
        node.position = pos
    end
end

---@param npcId string
---@param targetPos Vector3
function NPCManager.FaceTowards(npcId, targetPos)
    local node = npcNodes_[npcId]
    if not node then return end

    local npcPos = node.position
    local dir = targetPos - npcPos
    dir.y = 0

    if dir:Length() > 0.01 then
        local angle = math.deg(math.atan(dir.x, dir.z))
        node.rotation = Quaternion(angle, Vector3.UP)
    end
end

return NPCManager
