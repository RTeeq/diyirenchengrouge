-- ============================================================================
-- ItemSpawner.lua — 物品生成器
-- 在场景中放置可拾取物品
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")

local ItemSpawner = {}

-- 已生成物品节点
local itemNodes_ = {}  -- { [itemId] = node }

-- 物品配置：位置、颜色、浮动参数
local ITEM_CONFIGS = {
    [GameConfig.Items.FIRE_DRAGON_CARD] = {
        pos = Vector3(4, 0.8, -16),        -- 告示牌旁（市集入口附近）
        color = Color(0.85, 0.30, 0.15, 1.0),
        bobHeight = 0.15,
    },
    [GameConfig.Items.SECRET_KEY] = {
        pos = Vector3(-6, 1.2, 14),        -- 村长家与民居1之间的空地
        color = Color(0.78, 0.65, 0.20, 1.0),
        bobHeight = 0.12,
    },
    [GameConfig.Items.EXORCISM_TALISMAN] = {
        pos = Vector3(5, 1.0, -18),        -- 市集摊位旁
        color = Color(0.90, 0.80, 0.20, 1.0),
        bobHeight = 0.1,
    },
    [GameConfig.Items.MYSTERY_FRAGMENT] = {
        pos = Vector3(3, 0.6, 26),         -- 通往庙宇的石板路上
        color = Color(0.50, 0.75, 0.95, 1.0),
        bobHeight = 0.18,
    },
    [GameConfig.Items.SEALED_SCROLL] = {
        pos = Vector3(-3, 1.5, 33),        -- 庙宇台阶前方（庙前沿z=35外侧）
        color = Color(0.90, 0.82, 0.65, 1.0),
        bobHeight = 0.14,
    },
    [GameConfig.Items.SECRET_BOX] = {
        pos = Vector3(-4, 0.55, -5),       -- 广场南侧路旁（远离所有建筑）
        color = Color(0.55, 0.35, 0.20, 1.0),
        bobHeight = 0.1,
    },
}

-- 动画时间累计
local animTime_ = 0

-- ============================================================================
-- 材质工具
-- ============================================================================

local matCache_ = {}

local function makeMat(color)
    local key = string.format("%.2f_%.2f_%.2f", color.r, color.g, color.b)
    if matCache_[key] then return matCache_[key] end
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(0.92))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    matCache_[key] = mat
    return mat
end

local function makeGlow(color, intensity)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(
        color.r * intensity, color.g * intensity, color.b * intensity, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.92))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    return mat
end

-- ============================================================================
-- 物品多部件模型构建器
-- ============================================================================

--- 火龙帖：红色卡片 + 龙纹浮雕 + 火焰边框 + 封印章
local function buildFireDragonCard(inner, cfg)
    -- 主体卡片
    local card = inner:CreateChild("Card")
    local mdl = card:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 1.5))
    card.scale = Vector3(0.3, 0.4, 0.04)
    mdl.castShadows = true

    -- 边框（四条暗红色条）
    local darkRed = makeMat(Color(0.5, 0.12, 0.08, 1.0))
    local borders = {
        {Vector3(0, 0.21, 0), Vector3(0.32, 0.02, 0.05)},   -- 上
        {Vector3(0, -0.21, 0), Vector3(0.32, 0.02, 0.05)},   -- 下
        {Vector3(-0.16, 0, 0), Vector3(0.02, 0.42, 0.05)},   -- 左
        {Vector3(0.16, 0, 0), Vector3(0.02, 0.42, 0.05)},    -- 右
    }
    for i, b in ipairs(borders) do
        local brd = inner:CreateChild("Border" .. i)
        mdl = brd:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(darkRed)
        brd.position = b[1]
        brd.scale = b[2]
    end

    -- 龙纹浮雕（菱形）
    local emblem = inner:CreateChild("DragonEmblem")
    mdl = emblem:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Pyramid.mdl"))
    mdl:SetMaterial(makeGlow(Color(1.0, 0.6, 0.1, 1.0), 2.0))
    emblem.scale = Vector3(0.1, 0.08, 0.1)
    emblem.position = Vector3(0, 0.05, 0.03)

    -- 封印圆章
    local seal = inner:CreateChild("Seal")
    mdl = seal:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(makeMat(Color(0.9, 0.15, 0.1, 1.0)))
    seal.scale = Vector3(0.06, 0.01, 0.06)
    seal.position = Vector3(0.08, -0.1, 0.025)

    -- 发光点光
    local pl = inner:CreateChild("GlowLight")
    local light = pl:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 2.0
    light.color = Color(1.0, 0.4, 0.1, 1.0)
    light.brightness = 1.5
    pl.position = Vector3(0, 0, 0.1)
end

--- 秘钥：钥匙造型（柄 + 齿 + 环）
local function buildSecretKey(inner, cfg)
    local goldMat = makeGlow(cfg.color, 1.2)
    local darkGold = makeMat(Color(0.5, 0.4, 0.12, 1.0))

    -- 钥匙柄（主杆）
    local shaft = inner:CreateChild("Shaft")
    local mdl = shaft:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(goldMat)
    shaft.scale = Vector3(0.03, 0.25, 0.03)
    mdl.castShadows = true

    -- 钥匙环（顶部圆环）
    local ring = inner:CreateChild("Ring")
    mdl = ring:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(goldMat)
    ring.scale = Vector3(0.08, 0.08, 0.08)
    ring.position = Vector3(0, 0.15, 0)

    -- 钥匙齿（底部3个方块）
    for i = 1, 3 do
        local tooth = inner:CreateChild("Tooth" .. i)
        mdl = tooth:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(darkGold)
        tooth.scale = Vector3(0.04, 0.03 + i * 0.01, 0.02)
        tooth.position = Vector3(0.03, -0.12 - (i - 1) * 0.03, 0)
    end

    -- 宝石镶嵌（环上）
    local gem = inner:CreateChild("Gem")
    mdl = gem:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(Color(0.2, 0.8, 0.3, 1.0), 3.0))
    gem.scale = Vector3(0.025, 0.025, 0.025)
    gem.position = Vector3(0, 0.15, 0)

    -- 发光
    local pl = inner:CreateChild("GlowLight")
    local light = pl:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 1.5
    light.color = Color(0.9, 0.8, 0.3, 1.0)
    light.brightness = 1.2
    pl.position = Vector3(0, 0, 0.05)
end

--- 退魔符：黄色符纸 + 朱砂纹 + 流苏
local function buildExorcismTalisman(inner, cfg)
    -- 符纸主体
    local paper = inner:CreateChild("Paper")
    local mdl = paper:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 1.2))
    paper.scale = Vector3(0.18, 0.28, 0.02)
    mdl.castShadows = true

    -- 朱砂符文（中心竖线）
    local line1 = inner:CreateChild("Rune1")
    mdl = line1:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeMat(Color(0.8, 0.1, 0.05, 1.0)))
    line1.scale = Vector3(0.02, 0.18, 0.005)
    line1.position = Vector3(0, 0, 0.012)

    -- 朱砂符文（横线）
    local line2 = inner:CreateChild("Rune2")
    mdl = line2:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeMat(Color(0.8, 0.1, 0.05, 1.0)))
    line2.scale = Vector3(0.1, 0.02, 0.005)
    line2.position = Vector3(0, 0.04, 0.012)

    -- 朱砂圆印
    local stamp = inner:CreateChild("Stamp")
    mdl = stamp:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(makeMat(Color(0.8, 0.1, 0.05, 1.0)))
    stamp.scale = Vector3(0.04, 0.005, 0.04)
    stamp.position = Vector3(0, -0.08, 0.012)

    -- 流苏（底部两条）
    for i, side in ipairs({-1, 1}) do
        local tassel = inner:CreateChild("Tassel" .. i)
        mdl = tassel:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(makeMat(Color(0.8, 0.1, 0.05, 1.0)))
        tassel.scale = Vector3(0.008, 0.08, 0.008)
        tassel.position = Vector3(side * 0.04, -0.18, 0)
    end

    -- 发光
    local pl = inner:CreateChild("GlowLight")
    local light = pl:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 1.8
    light.color = Color(0.9, 0.8, 0.2, 1.0)
    light.brightness = 1.0
    pl.position = Vector3(0, 0, 0.05)
end

--- 神秘碎片：水晶碎片（多面体 + 内核发光 + 碎片环绕）
local function buildMysteryFragment(inner, cfg)
    -- 主晶体
    local crystal = inner:CreateChild("Crystal")
    local mdl = crystal:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Pyramid.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 2.0))
    crystal.scale = Vector3(0.15, 0.25, 0.15)
    mdl.castShadows = true

    -- 倒置底座晶体
    local base = inner:CreateChild("BaseCrystal")
    mdl = base:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Pyramid.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 1.5))
    base.scale = Vector3(0.1, 0.12, 0.1)
    base.position = Vector3(0, -0.05, 0)
    base.rotation = Quaternion(180, Vector3.RIGHT)

    -- 内核发光球
    local core = inner:CreateChild("Core")
    mdl = core:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(Color(0.7, 0.9, 1.0, 1.0), 4.0))
    core.scale = Vector3(0.06, 0.06, 0.06)
    core.position = Vector3(0, 0.08, 0)

    -- 环绕碎片（3个小金字塔）
    for i = 1, 3 do
        local shard = inner:CreateChild("Shard" .. i)
        mdl = shard:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Pyramid.mdl"))
        mdl:SetMaterial(makeGlow(cfg.color, 1.0))
        shard.scale = Vector3(0.04, 0.06, 0.04)
        local ang = math.rad((i - 1) * 120)
        shard.position = Vector3(math.sin(ang) * 0.12, 0.08, math.cos(ang) * 0.12)
        shard.rotation = Quaternion(i * 30, Vector3.UP)
    end

    -- 发光
    local pl = inner:CreateChild("GlowLight")
    local light = pl:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 3.0
    light.color = cfg.color
    light.brightness = 2.0
    pl.position = Vector3(0, 0.1, 0)
end

--- 封印卷轴：卷轴造型（圆柱主体 + 卷轴端 + 绑绳 + 封蜡）
local function buildSealedScroll(inner, cfg)
    local scrollMat = makeGlow(cfg.color, 1.0)
    local woodMat = makeMat(Color(0.4, 0.25, 0.12, 1.0))

    -- 卷轴主体
    local body = inner:CreateChild("ScrollBody")
    local mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(scrollMat)
    body.scale = Vector3(0.06, 0.3, 0.06)
    body.rotation = Quaternion(90, Vector3.FORWARD)
    mdl.castShadows = true

    -- 卷轴两端（木头帽）
    for i, side in ipairs({-1, 1}) do
        local cap = inner:CreateChild("Cap" .. i)
        mdl = cap:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(woodMat)
        cap.scale = Vector3(0.08, 0.02, 0.08)
        cap.position = Vector3(side * 0.16, 0, 0)
        cap.rotation = Quaternion(90, Vector3.FORWARD)
    end

    -- 绑绳
    local rope = inner:CreateChild("Rope")
    mdl = rope:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeMat(Color(0.35, 0.2, 0.1, 1.0)))
    rope.scale = Vector3(0.05, 0.05, 0.05)
    rope.position = Vector3(0, 0, 0)
    rope.rotation = Quaternion(90, Vector3.FORWARD)

    -- 封蜡印
    local seal = inner:CreateChild("WaxSeal")
    mdl = seal:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(makeMat(Color(0.7, 0.12, 0.08, 1.0)))
    seal.scale = Vector3(0.03, 0.008, 0.03)
    seal.position = Vector3(0, 0.065, 0)

    -- 发光
    local pl = inner:CreateChild("GlowLight")
    local light = pl:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 1.5
    light.color = Color(0.9, 0.8, 0.5, 1.0)
    light.brightness = 1.0
    pl.position = Vector3(0, 0.05, 0)
end

--- 秘箱：木盒（盒体 + 盖 + 金属件 + 锁 + 角件）
local function buildSecretBox(inner, cfg)
    local woodMat = makeMat(cfg.color)
    local metalMat = makeMat(Color(0.5, 0.45, 0.3, 1.0))
    local darkWood = makeMat(Color(0.35, 0.22, 0.12, 1.0))

    -- 盒体
    local body = inner:CreateChild("BoxBody")
    local mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(woodMat)
    body.scale = Vector3(0.25, 0.14, 0.18)
    mdl.castShadows = true

    -- 盒盖
    local lid = inner:CreateChild("Lid")
    mdl = lid:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(darkWood)
    lid.scale = Vector3(0.26, 0.03, 0.19)
    lid.position = Vector3(0, 0.085, 0)

    -- 金属锁扣
    local lock = inner:CreateChild("Lock")
    mdl = lock:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(metalMat)
    lock.scale = Vector3(0.04, 0.04, 0.02)
    lock.position = Vector3(0, 0.03, 0.095)

    -- 锁孔
    local keyhole = inner:CreateChild("Keyhole")
    mdl = keyhole:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(makeMat(Color(0.2, 0.2, 0.2, 1.0)))
    keyhole.scale = Vector3(0.008, 0.005, 0.008)
    keyhole.position = Vector3(0, 0.03, 0.1)

    -- 金属角件（4个）
    local corners = {
        Vector3(-0.125, -0.07, 0.09),
        Vector3(0.125, -0.07, 0.09),
        Vector3(-0.125, -0.07, -0.09),
        Vector3(0.125, -0.07, -0.09),
    }
    for i, pos in ipairs(corners) do
        local corner = inner:CreateChild("Corner" .. i)
        mdl = corner:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(metalMat)
        corner.scale = Vector3(0.03, 0.03, 0.03)
        corner.position = pos
    end

    -- 铰链（背面两个）
    for i = 1, 2 do
        local hinge = inner:CreateChild("Hinge" .. i)
        mdl = hinge:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(metalMat)
        hinge.scale = Vector3(0.015, 0.03, 0.015)
        hinge.position = Vector3((i * 2 - 3) * 0.06, 0.07, -0.09)
        hinge.rotation = Quaternion(90, Vector3.FORWARD)
    end
end

-- 物品 ID → 构建器映射
local ITEM_BUILDERS = {
    [GameConfig.Items.FIRE_DRAGON_CARD]  = buildFireDragonCard,
    [GameConfig.Items.SECRET_KEY]        = buildSecretKey,
    [GameConfig.Items.EXORCISM_TALISMAN] = buildExorcismTalisman,
    [GameConfig.Items.MYSTERY_FRAGMENT]  = buildMysteryFragment,
    [GameConfig.Items.SEALED_SCROLL]     = buildSealedScroll,
    [GameConfig.Items.SECRET_BOX]        = buildSecretBox,
}

-- ============================================================================
-- 创建物品模型
-- ============================================================================

---@param parent Node
---@param itemId string
---@param cfg table
---@return Node
local function createItemModel(parent, itemId, cfg)
    local node = parent:CreateChild("Item_" .. itemId)
    node.position = cfg.pos

    -- 内层节点（用于上下浮动动画）
    local inner = node:CreateChild("Inner")

    -- 查找专用构建器
    local builder = ITEM_BUILDERS[itemId]
    if builder then
        builder(inner, cfg)
    else
        -- 降级：单个发光球
        local mdl = inner:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.color, 1.5))
        inner.scale = Vector3(0.2, 0.2, 0.2)
        mdl.castShadows = true
    end

    -- 设置交互标记
    node:SetVar("InteractType", Variant("item"))
    node:SetVar("ItemId", Variant(itemId))

    -- 碰撞体（Trigger层：玩家物理体不碰撞，射线检测仍可命中）
    local rb = node:CreateComponent("RigidBody")
    rb.mass = 0
    rb.collisionLayer = CollisionLayerTrigger
    local shape = node:CreateComponent("CollisionShape")
    shape:SetSphere(0.5, Vector3.ZERO)

    return node
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 在场景中生成所有物品
---@param scene Scene
function ItemSpawner.SpawnAll(scene)
    local world = scene:GetChild("Village")
    if not world then
        world = scene:CreateChild("Village")
    end

    local itemParent = world:CreateChild("Items")

    for itemId, cfg in pairs(ITEM_CONFIGS) do
        -- 跳过已拥有的物品
        if not GameManager.HasItem(itemId) then
            local node = createItemModel(itemParent, itemId, cfg)
            itemNodes_[itemId] = node
        end
    end

    print("[ItemSpawner] 物品已生成")
end

--- 获取物品配置表（编辑器用）
---@return table
function ItemSpawner.GetConfigs()
    return ITEM_CONFIGS
end

--- 获取物品节点
---@param itemId string
---@return Node|nil
function ItemSpawner.GetNode(itemId)
    return itemNodes_[itemId]
end

--- 更新物品位置
---@param itemId string
---@param pos Vector3
function ItemSpawner.UpdateItemTransform(itemId, pos)
    local node = itemNodes_[itemId]
    if node then
        node.position = pos
        local cfg = ITEM_CONFIGS[itemId]
        if cfg then
            cfg.pos = pos
        end
    end
end

--- 重新生成所有物品（新游戏/重生时调用）
---@param scene Scene
function ItemSpawner.RespawnAll(scene)
    -- 移除现有物品节点
    for itemId, node in pairs(itemNodes_) do
        if node:GetParent() ~= nil then
            node:Remove()
        end
    end
    itemNodes_ = {}
    animTime_ = 0

    -- 重新生成
    ItemSpawner.SpawnAll(scene)
end

--- 移除指定物品（拾取后）
---@param itemId string
function ItemSpawner.RemoveItem(itemId)
    local node = itemNodes_[itemId]
    if node then
        node:Remove()
        itemNodes_[itemId] = nil
    end
end

--- 每帧更新：浮动动画
---@param dt number
function ItemSpawner.Update(dt)
    animTime_ = animTime_ + dt

    for itemId, node in pairs(itemNodes_) do
        local cfg = ITEM_CONFIGS[itemId]
        if cfg and node:GetParent() ~= nil then
            local inner = node:GetChild("Inner")
            if inner then
                -- 上下浮动
                local bob = math.sin(animTime_ * 2.0 + #itemId) * (cfg.bobHeight or 0.1)
                inner.position = Vector3(0, bob, 0)
                -- 缓慢旋转
                inner.rotation = Quaternion(animTime_ * 45, Vector3.UP)
            end
        end
    end
end

return ItemSpawner
