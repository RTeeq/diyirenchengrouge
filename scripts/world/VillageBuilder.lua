-- ============================================================================
-- VillageBuilder.lua — 罗坪村 + 大世界场景构建（三渲二风格·高精度版）
-- 地图尺寸: 800×800 米
-- 布局: 环形村庄（中央广场 → 环形道路 → 房屋区 → 农田 → 密林 → 荒野 → 边界）
-- ============================================================================

local GameConfig = require("config.GameConfig")

local VillageBuilder = {}

-- 地图半径 (总 800m, 半径 400m)
local MAP_HALF = 400
local BOUNDARY_DIST = 395
local WALL_HEIGHT = 12
local WALL_THICK = 2

-- 材质缓存
local matCache = {}
local function getMat(colorName)
    if not matCache[colorName] then
        matCache[colorName] = GameConfig.CreateMaterial(GameConfig.Colors[colorName])
    end
    return matCache[colorName]
end

local function getCustomMat(color)
    return GameConfig.CreateMaterial(color)
end

-- ============================================================================
-- 基础构建工具
-- ============================================================================

local function createModel(parent, name, modelPath, material, pos, scale, rot)
    local node = parent:CreateChild(name)
    node.position = pos or Vector3.ZERO
    if scale then node.scale = scale end
    if rot then node.rotation = rot end
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(material)
    model.castShadows = true
    return node
end

local function createBox(parent, name, mat, pos, scale)
    return createModel(parent, name, "Models/Box.mdl", mat, pos, scale)
end

local function createSphere(parent, name, mat, pos, scale)
    return createModel(parent, name, "Models/Sphere.mdl", mat, pos, scale)
end

local function createCylinder(parent, name, mat, pos, scale)
    return createModel(parent, name, "Models/Cylinder.mdl", mat, pos, scale)
end

local function createCone(parent, name, mat, pos, scale)
    return createModel(parent, name, "Models/Cone.mdl", mat, pos, scale)
end

local function createPyramid(parent, name, mat, pos, scale)
    return createModel(parent, name, "Models/Pyramid.mdl", mat, pos, scale)
end

-- 简单伪随机种子
local rngSeed = 42
local function seededRandom()
    rngSeed = (rngSeed * 1103515245 + 12345) % 2147483648
    return (rngSeed % 10000) / 10000.0
end

local function seededRange(lo, hi)
    return lo + seededRandom() * (hi - lo)
end

-- ============================================================================
-- 门动画系统
-- ============================================================================

local doorAnimations_ = {}

local function setDoorCollision(doorPivot, enabled)
    -- doorPivot 下的第一个子节点就是 door 节点（含 RigidBody）
    local doorNode = doorPivot:GetChild("door")
    if not doorNode then
        -- 回退：遍历子节点查找带 RigidBody 的
        for i = 0, doorPivot:GetNumChildren() - 1 do
            local child = doorPivot:GetChild(i)
            if child:GetComponent("RigidBody") then
                doorNode = child
                break
            end
        end
    end
    if doorNode then
        local rb = doorNode:GetComponent("RigidBody")
        if rb then
            rb.collisionLayer = enabled and CollisionLayerStatic or CollisionLayerNone
        end
    end
end

local function updateDoorAnimations(dt)
    for i = #doorAnimations_, 1, -1 do
        local anim = doorAnimations_[i]
        anim.elapsed = anim.elapsed + dt
        local t = math.min(anim.elapsed / anim.duration, 1.0)
        local smooth = t * t * (3 - 2 * t)
        local angle = anim.startAngle + (anim.endAngle - anim.startAngle) * smooth
        anim.node.rotation = Quaternion(angle, Vector3.UP)
        if t >= 1.0 then
            -- 动画结束：关门时恢复碰撞
            if anim.endAngle == 0 then
                setDoorCollision(anim.node, true)
            end
            table.remove(doorAnimations_, i)
        end
    end
end

---@param doorNode Node
local function toggleDoor(doorNode)
    local isOpen = doorNode:GetVar("DoorOpen")
    local open = isOpen ~= nil and not isOpen:IsEmpty() and isOpen:GetBool()
    local startAngle = open and 90 or 0
    local endAngle = open and 0 or 90
    doorNode:SetVar("DoorOpen", Variant(not open))

    -- 开门时立即禁用碰撞，关门时等动画结束再恢复
    if not open then
        setDoorCollision(doorNode, false)
    end

    for i = #doorAnimations_, 1, -1 do
        if doorAnimations_[i].node == doorNode then
            table.remove(doorAnimations_, i)
        end
    end
    table.insert(doorAnimations_, {
        node = doorNode,
        startAngle = startAngle,
        endAngle = endAngle,
        elapsed = 0,
        duration = 0.5,
    })
end

-- ============================================================================
-- 高精度建筑构建
-- ============================================================================

--- 创建一栋高精度房屋
local function createHouse(parent, name, pos, wallColor, roofColor, w, h, d)
    w = w or 4; h = h or 3; d = d or 5
    local house = parent:CreateChild(name)
    house.position = pos

    -- 主体墙壁
    local wallNode = createBox(house, "wall", getMat(wallColor),
        Vector3(0, h / 2, 0), Vector3(w, h, d))
    local wallRB = wallNode:CreateComponent("RigidBody")
    wallRB.mass = 0; wallRB.collisionLayer = CollisionLayerStatic
    local wallShape = wallNode:CreateComponent("CollisionShape")
    wallShape:SetBox(Vector3(1, 1, 1))

    -- 屋顶（Pyramid 主体）
    createPyramid(house, "roof", getMat(roofColor),
        Vector3(0, h + 0.8, 0), Vector3(w + 0.8, 1.6, d + 0.8))

    -- 屋檐（薄板突出）
    local eaveMat = getCustomMat(Color(
        GameConfig.Colors[roofColor].r * 0.85,
        GameConfig.Colors[roofColor].g * 0.85,
        GameConfig.Colors[roofColor].b * 0.85, 1.0))
    createBox(house, "eaveF", eaveMat,
        Vector3(0, h + 0.05, d / 2 + 0.35), Vector3(w + 1.2, 0.1, 0.7))
    createBox(house, "eaveB", eaveMat,
        Vector3(0, h + 0.05, -d / 2 - 0.35), Vector3(w + 1.2, 0.1, 0.7))
    createBox(house, "eaveL", eaveMat,
        Vector3(-w / 2 - 0.35, h + 0.05, 0), Vector3(0.7, 0.1, d + 0.5))
    createBox(house, "eaveR", eaveMat,
        Vector3(w / 2 + 0.35, h + 0.05, 0), Vector3(0.7, 0.1, d + 0.5))

    -- 门框
    local frameMat = getMat("TreeTrunk")
    createBox(house, "doorFrameL", frameMat,
        Vector3(-0.55, 1.0, d / 2 + 0.03), Vector3(0.1, 2.0, 0.12))
    createBox(house, "doorFrameR", frameMat,
        Vector3(0.55, 1.0, d / 2 + 0.03), Vector3(0.1, 2.0, 0.12))
    createBox(house, "doorFrameT", frameMat,
        Vector3(0, 2.05, d / 2 + 0.03), Vector3(1.2, 0.1, 0.12))

    -- 门（枢轴旋转）
    local doorPivot = house:CreateChild("doorPivot")
    doorPivot.position = Vector3(-0.5, 0, d / 2 + 0.02)
    local doorNode = createBox(doorPivot, "door", getMat("WoodDoor"),
        Vector3(0.5, 1.0, 0), Vector3(1.0, 2.0, 0.1))
    local doorRB = doorNode:CreateComponent("RigidBody")
    doorRB.mass = 0; doorRB.collisionLayer = CollisionLayerStatic
    local doorShape = doorNode:CreateComponent("CollisionShape")
    doorShape:SetBox(Vector3(1, 1, 1))
    doorPivot:SetVar("InteractType", Variant("door"))
    doorPivot:SetVar("DoorOpen", Variant(false))
    doorPivot:SetVar("DoorName", Variant(name))

    -- 窗户（两侧各一个）
    local windowFrameMat = frameMat
    local windowGlassMat = GameConfig.CreateAlphaMaterial(
        Color(0.6, 0.75, 0.85, 0.5))
    -- 左侧窗
    local wy = h * 0.55
    createBox(house, "winL_frame", windowFrameMat,
        Vector3(-w / 2 - 0.03, wy, 0), Vector3(0.12, 0.9, 0.9))
    createBox(house, "winL_glass", windowGlassMat,
        Vector3(-w / 2 - 0.03, wy, 0), Vector3(0.06, 0.7, 0.7))
    -- 右侧窗
    createBox(house, "winR_frame", windowFrameMat,
        Vector3(w / 2 + 0.03, wy, 0), Vector3(0.12, 0.9, 0.9))
    createBox(house, "winR_glass", windowGlassMat,
        Vector3(w / 2 + 0.03, wy, 0), Vector3(0.06, 0.7, 0.7))

    -- 台阶（门口两级）
    local stepMat = getMat("Stone")
    createBox(house, "step1", stepMat,
        Vector3(0, 0.1, d / 2 + 0.4), Vector3(1.4, 0.2, 0.4))
    createBox(house, "step2", stepMat,
        Vector3(0, 0.05, d / 2 + 0.75), Vector3(1.8, 0.1, 0.3))

    -- 烟囱（右后角）
    createBox(house, "chimney", getMat("Rock"),
        Vector3(w / 2 - 0.5, h + 1.0, -d / 2 + 0.5), Vector3(0.5, 1.2, 0.5))

    -- 半木结构装饰横梁（正面）
    local beamMat = getMat("TreeTrunk")
    createBox(house, "beamH1", beamMat,
        Vector3(0, h * 0.35, d / 2 + 0.03), Vector3(w * 0.9, 0.08, 0.06))
    createBox(house, "beamH2", beamMat,
        Vector3(0, h * 0.7, d / 2 + 0.03), Vector3(w * 0.9, 0.08, 0.06))

    -- 地基石条
    createBox(house, "foundation", getMat("Stone"),
        Vector3(0, 0.08, 0), Vector3(w + 0.3, 0.16, d + 0.3))

    return house
end

--- 用官方资产库 prefab 创建房屋（单 StaticModel + 碰撞体）
--- @param parent Node    父节点
--- @param name   string  节点名
--- @param pos    Vector3 世界坐标（Y=0 即地面）
--- @param modelUUID string 模型 uuid
--- @param matList   table  材质 uuid 数组
--- @param halfH  number  模型半高（用于碰撞盒偏移）
--- @param sx number 碰撞盒 X
--- @param sy number 碰撞盒 Y
--- @param sz number 碰撞盒 Z
local function createPrefabHouse(parent, name, pos, modelUUID, matList, halfH, sx, sy, sz)
    local node = parent:CreateChild(name)
    -- 资产库模型 pivot 在底部，直接放 Y=0，不需要额外偏移
    node.position = Vector3(pos.x, pos.y, pos.z)
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", modelUUID))
    -- 逐个设置子网格材质（多材质模型）
    for i, matUUID in ipairs(matList) do
        mdl:SetMaterial(i - 1, cache:GetResource("Material", matUUID))
    end
    mdl.castShadows = true
    -- 碰撞体（静态盒形）—— pivot 在底部，碰撞盒中心需上移半高
    local rb = node:CreateComponent("RigidBody")
    rb.mass = 0
    rb.collisionLayer = CollisionLayerStatic
    local cs = node:CreateComponent("CollisionShape")
    cs:SetBox(Vector3(sx, sy, sz), Vector3(0, halfH, 0))
    return node
end

--- 创建高精度树木（多层树冠 + 树根 + 分叉枝干）
local function createTree(parent, name, pos, leafColor, trunkH, crownR)
    trunkH = trunkH or 2.0; crownR = crownR or 1.5
    leafColor = leafColor or "TreeLeaves"
    local tree = parent:CreateChild(name)
    tree.position = pos

    -- 树干
    createCylinder(tree, "trunk", getMat("TreeTrunk"),
        Vector3(0, trunkH / 2, 0), Vector3(0.25, trunkH, 0.25))

    -- 树根（底部粗壮部分）
    createCone(tree, "root", getMat("TreeTrunk"),
        Vector3(0, 0.15, 0), Vector3(0.6, 0.3, 0.6))

    -- 主冠（大球）
    createSphere(tree, "crown", getMat(leafColor),
        Vector3(0, trunkH + crownR * 0.5, 0), Vector3(crownR * 2, crownR * 1.8, crownR * 2))

    -- 中层冠（略小，偏移）
    createSphere(tree, "crown2", getMat(leafColor),
        Vector3(crownR * 0.3, trunkH + crownR * 0.9, crownR * 0.2),
        Vector3(crownR * 1.4, crownR * 1.2, crownR * 1.4))

    -- 顶冠（小球突出）
    createSphere(tree, "crown3", getMat(leafColor),
        Vector3(-crownR * 0.15, trunkH + crownR * 1.3, 0),
        Vector3(crownR * 0.9, crownR * 0.8, crownR * 0.9))

    -- 分叉枝干（一侧）
    local branchH = trunkH * 0.6
    createCylinder(tree, "branch1", getMat("TreeTrunk"),
        Vector3(0.3, branchH, 0.1), Vector3(0.08, 0.6, 0.08))
    local brNode = tree:GetChild("branch1")
    if brNode then brNode.rotation = Quaternion(30, Vector3.FORWARD) end

    return tree
end

--- 创建篱笆段
local function createFence(parent, name, startX, endX, z, y)
    y = y or 0
    local len = math.abs(endX - startX)
    local midX = (startX + endX) / 2
    -- 横栏
    createBox(parent, name, getMat("WoodFence"),
        Vector3(midX, y + 0.6, z), Vector3(len, 0.1, 0.08))
    createBox(parent, name .. "_lo", getMat("WoodFence"),
        Vector3(midX, y + 0.3, z), Vector3(len, 0.1, 0.08))
    -- 支柱（每3米一根）
    local postCount = math.max(2, math.floor(len / 3))
    for i = 0, postCount do
        local px = startX + (endX - startX) * i / postCount
        createCylinder(parent, name .. "_post" .. i, getMat("TreeTrunk"),
            Vector3(px, y + 0.4, z), Vector3(0.06, 0.8, 0.06))
    end
end

--- 创建石头
local function createRock(parent, name, pos, s)
    s = s or 0.6
    createSphere(parent, name, getMat("Rock"),
        pos, Vector3(s, s * 0.6, s))
end

--- 创建大岩石（带碰撞体）
local function createBigRock(parent, name, pos, sx, sy, sz)
    sx = sx or 2.0; sy = sy or 1.5; sz = sz or 2.0
    local node = createSphere(parent, name, getMat("Rock"), pos, Vector3(sx, sy, sz))
    local rb = node:CreateComponent("RigidBody")
    rb.mass = 0
    local shape = node:CreateComponent("CollisionShape")
    shape:SetSphere(0.9, Vector3.ZERO)
    return node
end

--- 创建石灯笼（日式风格）
local function createStoneLantern(parent, name, pos)
    local lantern = parent:CreateChild(name)
    lantern.position = pos
    local stoneMat = getMat("Stone")
    -- 基座
    createBox(lantern, "base", stoneMat, Vector3(0, 0.15, 0), Vector3(0.6, 0.3, 0.6))
    -- 柱子
    createCylinder(lantern, "pillar", stoneMat, Vector3(0, 0.8, 0), Vector3(0.2, 1.0, 0.2))
    -- 灯室
    local glowMat = GameConfig.CreateEmissiveMaterial(Color(0.9, 0.7, 0.3, 1.0), 1.5)
    createBox(lantern, "chamber", glowMat, Vector3(0, 1.4, 0), Vector3(0.5, 0.4, 0.5))
    -- 笠（屋顶）
    createPyramid(lantern, "cap", stoneMat, Vector3(0, 1.8, 0), Vector3(0.7, 0.4, 0.7))
    return lantern
end

--- 创建花坛
local function createFlowerBed(parent, name, pos, radius)
    radius = radius or 1.5
    local fb = parent:CreateChild(name)
    fb.position = pos
    -- 石围
    local stoneMat = getMat("Stone")
    createCylinder(fb, "ring", stoneMat, Vector3(0, 0.15, 0), Vector3(radius * 2, 0.3, radius * 2))
    -- 土壤
    createCylinder(fb, "soil", getMat("DirtPath"), Vector3(0, 0.18, 0), Vector3(radius * 1.8, 0.1, radius * 1.8))
    -- 花簇（彩色小球）
    local flowerColors = {
        Color(0.9, 0.3, 0.3, 1.0), Color(0.9, 0.8, 0.2, 1.0),
        Color(0.7, 0.3, 0.8, 1.0), Color(1.0, 0.6, 0.3, 1.0),
    }
    for i = 1, 6 do
        local angle = (i / 6) * math.pi * 2
        local r = radius * 0.55
        local fx = math.cos(angle) * r
        local fz = math.sin(angle) * r
        local fc = flowerColors[((i - 1) % #flowerColors) + 1]
        createSphere(fb, "flower" .. i, getCustomMat(fc),
            Vector3(fx, 0.35, fz), Vector3(0.25, 0.2, 0.25))
    end
    return fb
end

--- 创建火把
local function createTorch(parent, name, pos)
    local torch = parent:CreateChild(name)
    torch.position = pos
    createCylinder(torch, "pole", getMat("TreeTrunk"), Vector3(0, 1.2, 0), Vector3(0.06, 2.4, 0.06))
    local fireMat = GameConfig.CreateEmissiveMaterial(Color(1.0, 0.6, 0.1, 1.0), 3.0)
    createSphere(torch, "flame", fireMat, Vector3(0, 2.5, 0), Vector3(0.2, 0.3, 0.2))
    return torch
end

-- ============================================================================
-- 1. 村庄核心（环形布局）
-- ============================================================================

local function buildVillageCore(world)
    -- ==============================
    -- 中央广场（石板圆形）
    -- ==============================
    createCylinder(world, "Plaza", getMat("Stone"),
        Vector3(0, 0.02, 0), Vector3(14, 0.04, 14))

    -- 广场中心水井（精致版）
    local well = world:CreateChild("Well")
    well.position = Vector3(0, 0, 0)
    createCylinder(well, "wellBase", getMat("Stone"), Vector3(0, 0.4, 0), Vector3(1.4, 0.8, 1.4))
    createCylinder(well, "wellInner", getMat("Water"), Vector3(0, 0.35, 0), Vector3(0.9, 0.1, 0.9))
    -- 井架
    createCylinder(well, "wellPoleL", getMat("TreeTrunk"), Vector3(-0.5, 1.2, 0), Vector3(0.08, 1.6, 0.08))
    createCylinder(well, "wellPoleR", getMat("TreeTrunk"), Vector3(0.5, 1.2, 0), Vector3(0.08, 1.6, 0.08))
    createBox(well, "wellBeam", getMat("TreeTrunk"), Vector3(0, 2.0, 0), Vector3(1.2, 0.08, 0.08))
    createCylinder(well, "wellRoof", getMat("RoofBrown"), Vector3(0, 2.3, 0), Vector3(1.6, 0.1, 0.8))

    -- ==============================
    -- 环形主道路（八边形近似圆环）
    -- ==============================
    local ringR = 18  -- 环路半径
    local roadW = 3.0
    local segments = 12
    for i = 1, segments do
        local a1 = (i - 1) / segments * math.pi * 2
        local a2 = i / segments * math.pi * 2
        local mx = math.cos((a1 + a2) / 2) * ringR
        local mz = math.sin((a1 + a2) / 2) * ringR
        local segLen = 2 * ringR * math.sin(math.pi / segments) + 0.5
        local angle = math.deg((a1 + a2) / 2 + math.pi / 2)
        local roadNode = createBox(world, "RingRoad_" .. i, getMat("DirtPath"),
            Vector3(mx, 0.01, mz), Vector3(segLen, 0.02, roadW))
        roadNode.rotation = Quaternion(angle, Vector3.UP)
    end

    -- 放射状道路（通往四方）
    createBox(world, "RoadN", getMat("DirtPath"), Vector3(0, 0.01, 30), Vector3(3.0, 0.02, 30))
    createBox(world, "RoadS", getMat("DirtPath"), Vector3(0, 0.01, -30), Vector3(3.0, 0.02, 30))
    createBox(world, "RoadE", getMat("DirtPath"), Vector3(30, 0.01, 0), Vector3(30, 0.02, 3.0))
    createBox(world, "RoadW", getMat("DirtPath"), Vector3(-30, 0.01, 0), Vector3(30, 0.02, 3.0))

    -- 庙宇专用石板路
    createBox(world, "TempleRoad", getMat("Stone"),
        Vector3(0, 0.02, 30), Vector3(2.5, 0.02, 15))

    -- ==============================
    -- 房屋群（沿环路外侧分布）— 官方资产库模型
    -- ==============================

    -- 村长家（北偏西）— 木框架蓝瓦房屋（两层，15×19.77×17m，最大）
    createPrefabHouse(world, "CunzhangHouse", Vector3(-14, 0, 16),
        "uuid://CFwzwYJ15Ten_ukOf1ykayQN",
        {"uuid://HntT6UQGaB9sTTQOuRq_XVBm","uuid://BNIC6cvUGy3xIKIuvfjn3bUA",
         "uuid://CCpw6SQ3cEwfxBRAqILF4V4W","uuid://Bu1-aXStY3WMbN0SDgV_0J8L",
         "uuid://Bu1-aXStY3WMbN0SDgV_0J8L"},
        9.885, 15.08, 19.77, 17.20)

    -- 阿阳家（东侧）— 木框架小屋（单层，9.37×10.16×14m，红瓦卡通）
    createPrefabHouse(world, "AyangHouse", Vector3(16, 0, 7),
        "uuid://D6f5ARUOv2X7EEmXLSrx1AM9",
        {"uuid://Bu1-aXStY3WMbN0SDgV_0J8L","uuid://HntT6UQGaB9sTTQOuRq_XVBm",
         "uuid://HhdXudJoS_1n5psy_52upCCB","uuid://BYUaAXeDcr7-GOyrJkX2dGoW"},
        5.08, 9.37, 10.16, 14.18)

    -- 七七家（南偏西）— 木框架房屋（蓝顶，9.37×16.55×10.9m）
    createPrefabHouse(world, "QiqiHouse", Vector3(-12, 0, -14),
        "uuid://DzZ52YA_AJiGZFDf_BeMtVku",
        {"uuid://Bu1-aXStY3WMbN0SDgV_0J8L","uuid://HntT6UQGaB9sTTQOuRq_XVBm",
         "uuid://HhdXudJoS_1n5psy_52upCCB","uuid://CCpw6SQ3cEwfxBRAqILF4V4W",
         "uuid://BNIC6cvUGy3xIKIuvfjn3bUA"},
        8.275, 9.37, 16.55, 10.90)

    -- 嗡摩佬商店（东偏南）— 中世纪木屋（写实两层，14.47×16.65×15.83m）
    createPrefabHouse(world, "WengmolaoShop", Vector3(14, 0, -10),
        "uuid://FDwOaQVynTp2ZcJWO68eXmac",
        {"uuid://BNIC6cvUGy3xIKIuvfjn3bUA","uuid://Bu1-aXStY3WMbN0SDgV_0J8L",
         "uuid://HntT6UQGaB9sTTQOuRq_XVBm","uuid://BYUaAXeDcr7-GOyrJkX2dGoW",
         "uuid://HhdXudJoS_1n5psy_52upCCB","uuid://Al04uRzufR1q3TV13VuPQmGh",
         "uuid://Bu1-aXStY3WMbN0SDgV_0J8L"},
        8.325, 14.47, 16.65, 15.83)

    -- 民居1（西北）— 奇幻塔楼（10.52×41.64×15m，村庄地标）
    createPrefabHouse(world, "House1", Vector3(-20, 0, 8),
        "uuid://Fyr4-T8pjU0ovYW0yswqfW2P",
        {"uuid://BNIC6cvUGy3xIKIuvfjn3bUA","uuid://Bu1-aXStY3WMbN0SDgV_0J8L",
         "uuid://Bu1-aXStY3WMbN0SDgV_0J8L","uuid://HntT6UQGaB9sTTQOuRq_XVBm",
         "uuid://HhdXudJoS_1n5psy_52upCCB","uuid://CCpw6SQ3cEwfxBRAqILF4V4W",
         "uuid://Bu1-aXStY3WMbN0SDgV_0J8L"},
        20.82, 10.52, 41.64, 15.01)

    -- 民居2（北偏东）— 木框架小屋（红瓦，同款阿阳家，位置不同）
    createPrefabHouse(world, "House2", Vector3(12, 0, 18),
        "uuid://D6f5ARUOv2X7EEmXLSrx1AM9",
        {"uuid://Bu1-aXStY3WMbN0SDgV_0J8L","uuid://HntT6UQGaB9sTTQOuRq_XVBm",
         "uuid://HhdXudJoS_1n5psy_52upCCB","uuid://BYUaAXeDcr7-GOyrJkX2dGoW"},
        5.08, 9.37, 10.16, 14.18)

    -- ==============================
    -- 市集区域（南侧环路外）
    -- ==============================
    local market = world:CreateChild("Market")
    market.position = Vector3(0, 0, -18)
    -- 摊位棚架（三个）
    for i = 1, 3 do
        local sx = (i - 2) * 5
        local stall = market:CreateChild("Stall" .. i)
        stall.position = Vector3(sx, 0, 0)
        -- 柱子
        createCylinder(stall, "poleFL", getMat("TreeTrunk"),
            Vector3(-1.0, 1.0, 1.0), Vector3(0.08, 2.0, 0.08))
        createCylinder(stall, "poleFR", getMat("TreeTrunk"),
            Vector3(1.0, 1.0, 1.0), Vector3(0.08, 2.0, 0.08))
        createCylinder(stall, "poleBL", getMat("TreeTrunk"),
            Vector3(-1.0, 1.0, -0.5), Vector3(0.08, 2.0, 0.08))
        createCylinder(stall, "poleBR", getMat("TreeTrunk"),
            Vector3(1.0, 1.0, -0.5), Vector3(0.08, 2.0, 0.08))
        -- 顶棚
        local canvasColors = {
            Color(0.85, 0.25, 0.2, 1.0),
            Color(0.2, 0.55, 0.8, 1.0),
            Color(0.9, 0.75, 0.2, 1.0),
        }
        createBox(stall, "canopy", getCustomMat(canvasColors[i]),
            Vector3(0, 2.1, 0.25), Vector3(2.4, 0.06, 2.0))
        -- 台面
        createBox(stall, "counter", getMat("WoodFence"),
            Vector3(0, 0.75, 0.5), Vector3(2.0, 0.1, 1.0))
    end

    -- ==============================
    -- 庙宇（北方，升级版）
    -- ==============================
    local temple = world:CreateChild("Temple")
    temple.position = Vector3(0, 0, 38)

    -- 庙基（三级台阶）
    for i = 1, 3 do
        createBox(temple, "TempleStep" .. i, getMat("Stone"),
            Vector3(0, (i - 1) * 0.25 + 0.125, -3.5 - i * 0.6),
            Vector3(3.0 + i * 0.5, 0.25, 0.6))
    end

    -- 庙体
    local templeBody = createBox(temple, "TempleBody", getMat("Temple"),
        Vector3(0, 2.5, 0), Vector3(8, 5, 6))
    local templeRB = templeBody:CreateComponent("RigidBody")
    templeRB.mass = 0; templeRB.collisionLayer = CollisionLayerStatic
    local templeShape = templeBody:CreateComponent("CollisionShape")
    templeShape:SetBox(Vector3(1, 1, 1))

    -- 第一层屋顶
    createPyramid(temple, "TempleRoof1", getMat("RoofRed"),
        Vector3(0, 5.5, 0), Vector3(9.5, 1.8, 7.5))
    -- 第一层屋檐
    createBox(temple, "TempleEaveF", getMat("RoofRed"),
        Vector3(0, 5.1, -3.5), Vector3(10.0, 0.1, 1.0))
    createBox(temple, "TempleEaveB", getMat("RoofRed"),
        Vector3(0, 5.1, 3.5), Vector3(10.0, 0.1, 1.0))

    -- 第二层阁楼
    createBox(temple, "TempleUpper", getMat("Temple"),
        Vector3(0, 7.0, 0), Vector3(5, 2.0, 3.5))
    -- 第二层屋顶
    createPyramid(temple, "TempleRoof2", getMat("RoofRed"),
        Vector3(0, 8.3, 0), Vector3(6.0, 1.2, 4.5))

    -- 前廊柱（4根）
    for i = 1, 4 do
        local px = -3.0 + (i - 1) * 2.0
        createCylinder(temple, "Pillar" .. i, getMat("Stone"),
            Vector3(px, 2.5, -3.2), Vector3(0.3, 5.0, 0.3))
    end

    -- 匾额
    local plaqueMat = getCustomMat(Color(0.55, 0.15, 0.1, 1.0))
    createBox(temple, "Plaque", plaqueMat,
        Vector3(0, 4.0, -3.15), Vector3(2.5, 0.8, 0.1))

    -- 庙门（可交互）
    local templeDoorPivot = temple:CreateChild("doorPivot")
    templeDoorPivot.position = Vector3(-0.9, 0, -3.02)
    local templeDoorNode = createBox(templeDoorPivot, "door", getMat("WoodDoor"),
        Vector3(0.9, 1.5, 0), Vector3(1.8, 3.0, 0.1))
    local tdRB = templeDoorNode:CreateComponent("RigidBody")
    tdRB.mass = 0; tdRB.collisionLayer = CollisionLayerStatic
    local tdShape = templeDoorNode:CreateComponent("CollisionShape")
    tdShape:SetBox(Vector3(1, 1, 1))
    templeDoorPivot:SetVar("InteractType", Variant("door"))
    templeDoorPivot:SetVar("DoorOpen", Variant(false))
    templeDoorPivot:SetVar("DoorName", Variant("Temple"))

    -- 石灯笼（庙宇两侧）
    createStoneLantern(world, "TempleLanternL", Vector3(-4, 0, 34))
    createStoneLantern(world, "TempleLanternR", Vector3(4, 0, 34))

    -- ==============================
    -- 村门楼（南入口）
    -- ==============================
    local gate = world:CreateChild("Gate")
    gate.position = Vector3(0, 0, -28)
    -- 两根大柱
    createCylinder(gate, "gatePillarL", getMat("Stone"),
        Vector3(-2.5, 2.5, 0), Vector3(0.6, 5.0, 0.6))
    createCylinder(gate, "gatePillarR", getMat("Stone"),
        Vector3(2.5, 2.5, 0), Vector3(0.6, 5.0, 0.6))
    -- 顶梁
    createBox(gate, "gateBeam", getMat("RoofRed"),
        Vector3(0, 5.2, 0), Vector3(6.0, 0.4, 1.2))
    -- 牌匾
    createBox(gate, "gatePlaque", plaqueMat,
        Vector3(0, 4.5, 0), Vector3(2.8, 0.7, 0.1))
    -- 小屋顶
    createPyramid(gate, "gateRoof", getMat("RoofRed"),
        Vector3(0, 5.8, 0), Vector3(6.5, 1.0, 1.8))

    -- ==============================
    -- 河流 + 桥梁（东南方向）
    -- ==============================
    local waterMat = GameConfig.CreateAlphaMaterial(
        Color(GameConfig.Colors.Water.r, GameConfig.Colors.Water.g, GameConfig.Colors.Water.b, 0.7))
    createBox(world, "River", waterMat,
        Vector3(25, -0.05, -22), Vector3(60, 0.1, 4))
    local riverNode = world:GetChild("River")
    if riverNode then riverNode.rotation = Quaternion(20, Vector3.UP) end

    -- 石拱桥
    local bridge = world:CreateChild("Bridge")
    bridge.position = Vector3(25, 0, -22)
    bridge.rotation = Quaternion(20, Vector3.UP)
    createBox(bridge, "BridgeDeck", getMat("Bridge"),
        Vector3(0, 0.35, 0), Vector3(4.5, 0.5, 5.5))
    createBox(bridge, "BridgeRailL", getMat("Stone"),
        Vector3(-2.0, 0.9, 0), Vector3(0.2, 0.8, 5.5))
    createBox(bridge, "BridgeRailR", getMat("Stone"),
        Vector3(2.0, 0.9, 0), Vector3(0.2, 0.8, 5.5))
    -- 桥拱装饰
    createCylinder(bridge, "BridgeArch", getMat("Stone"),
        Vector3(0, -0.1, 0), Vector3(3.5, 0.15, 3.5))

    -- ==============================
    -- 村内树木（环路沿线点缀）
    -- ==============================
    local villageTrees = {
        { -5, -6, "DarkLeaves", 3.5, 2.5 },
        { 7, 2, "TreeLeaves", 2.5, 1.5 },
        { -8, 10, "TreeLeaves", 2.2, 1.4 },
        { 15, 12, "DarkLeaves", 2.8, 1.8 },
        { -14, -5, "DarkLeaves", 3.0, 2.0 },
        { 6, -14, "TreeLeaves", 2.0, 1.2 },
        { -4, 26, "DarkLeaves", 3.5, 2.2 },
        { 6, 30, "DarkLeaves", 3.0, 2.0 },
        { -20, 0, "TreeLeaves", 2.5, 2.0 },
        { 20, -4, "TreeLeaves", 2.2, 1.8 },
    }
    for i, t in ipairs(villageTrees) do
        createTree(world, "VTree_" .. i, Vector3(t[1], 0, t[2]), t[3], t[4], t[5])
    end

    -- ==============================
    -- 篱笆（村庄外围部分段）
    -- ==============================
    createFence(world, "FenceSW", -22, -6, -22)
    createFence(world, "FenceSE", 6, 22, -22)

    -- ==============================
    -- 花坛 + 装饰
    -- ==============================
    createFlowerBed(world, "FlowerBed1", Vector3(-5, 0, 3), 1.2)
    createFlowerBed(world, "FlowerBed2", Vector3(5, 0, -3), 1.0)

    -- 火把（广场四角）
    createTorch(world, "Torch1", Vector3(-6, 0, 6))
    createTorch(world, "Torch2", Vector3(6, 0, 6))
    createTorch(world, "Torch3", Vector3(-6, 0, -6))
    createTorch(world, "Torch4", Vector3(6, 0, -6))

    -- 告示牌
    createBox(world, "SignBoard", getMat("WoodFence"),
        Vector3(3, 1.0, -16), Vector3(1.2, 0.8, 0.1))
    createCylinder(world, "SignPole", getMat("TreeTrunk"),
        Vector3(3, 0.5, -16), Vector3(0.08, 1.0, 0.08))

    -- 石头装饰
    createRock(world, "Rock1", Vector3(8, 0.2, -15), 0.8)
    createRock(world, "Rock2", Vector3(-7, 0.15, 8), 0.5)
    createRock(world, "Rock3", Vector3(12, 0.1, 20), 0.4)
    createRock(world, "Rock4", Vector3(-3, 0.2, 32), 0.7)

    -- 灯笼（村门两侧）
    local lanternMat = GameConfig.CreateEmissiveMaterial(GameConfig.Colors.Lantern, 2.0)
    createCylinder(world, "LanternL_pole", getMat("WoodDoor"),
        Vector3(-4, 1.5, -28), Vector3(0.08, 3.0, 0.08))
    createBox(world, "LanternL", lanternMat,
        Vector3(-4, 2.8, -28), Vector3(0.4, 0.6, 0.4))
    createCylinder(world, "LanternR_pole", getMat("WoodDoor"),
        Vector3(4, 1.5, -28), Vector3(0.08, 3.0, 0.08))
    createBox(world, "LanternR", lanternMat,
        Vector3(4, 2.8, -28), Vector3(0.4, 0.6, 0.4))
end

-- ============================================================================
-- 2. 内环区域 (40-150m)
-- ============================================================================

local function buildInnerRing(world)
    local inner = world:CreateChild("InnerRing")

    -- 四条出村土路延伸
    createBox(inner, "RoadN", getMat("DirtPath"),
        Vector3(0, 0.01, 70), Vector3(3.0, 0.02, 80))
    createBox(inner, "RoadS", getMat("DirtPath"),
        Vector3(0, 0.01, -70), Vector3(3.0, 0.02, 80))
    createBox(inner, "RoadE", getMat("DirtPath"),
        Vector3(70, 0.01, 0), Vector3(80, 0.02, 3.0))
    createBox(inner, "RoadW", getMat("DirtPath"),
        Vector3(-70, 0.01, 0), Vector3(80, 0.02, 3.0))

    -- 农田区域（东北方向）
    local farmColor = Color(0.52, 0.70, 0.35, 1.0)
    local farmMat = getCustomMat(farmColor)
    for i = 1, 4 do
        for j = 1, 3 do
            createBox(inner, "Farm_" .. i .. "_" .. j, farmMat,
                Vector3(40 + i * 18, 0.015, 40 + j * 18),
                Vector3(14, 0.03, 14))
        end
    end

    -- 农田篱笆
    createFence(inner, "FarmFenceN", 40, 115, 100)
    createFence(inner, "FarmFenceS", 40, 115, 38)

    -- 稀疏树木
    rngSeed = 100
    local treeIdx = 0
    local treePositions = {
        { -50, -40 }, { -65, -55 }, { -80, -35 }, { -45, -70 },
        { -90, -50 }, { -55, -85 }, { -100, -70 }, { -70, -100 },
        { -50, 50 }, { -70, 65 }, { -85, 45 }, { -60, 80 },
        { -95, 75 }, { -45, 95 }, { -80, 105 }, { -110, 60 },
        { 55, -45 }, { 70, -60 }, { 85, -40 }, { 60, -80 },
        { 95, -55 }, { 50, -90 }, { 75, -95 }, { 105, -70 },
        { -20, 60 }, { 15, 70 }, { -30, 85 }, { 25, 95 },
        { -10, 110 }, { 35, 75 }, { -45, 100 }, { 40, 110 },
    }
    for _, tp in ipairs(treePositions) do
        treeIdx = treeIdx + 1
        local leafType = (treeIdx % 3 == 0) and "DarkLeaves" or "TreeLeaves"
        local h = 1.8 + seededRange(0, 2.0)
        local r = 1.0 + seededRange(0, 1.2)
        createTree(inner, "InTree_" .. treeIdx, Vector3(tp[1], 0, tp[2]), leafType, h, r)
    end

    -- 散落的石头
    local rockPositions = {
        { -60, -30, 0.7 }, { -40, 60, 0.5 }, { 50, -35, 0.8 },
        { 80, 50, 0.6 }, { -90, -80, 0.9 }, { 100, -40, 0.5 },
        { -75, 90, 0.7 }, { 45, 80, 0.6 },
    }
    for i, rp in ipairs(rockPositions) do
        createRock(inner, "InRock_" .. i, Vector3(rp[1], 0.15, rp[2]), rp[3])
    end

    -- 废弃水车（西边，精致版）
    local watermill = inner:CreateChild("Watermill")
    watermill.position = Vector3(-80, 0, 15)
    createBox(watermill, "Base", getMat("WoodFence"), Vector3(0, 1, 0), Vector3(3, 2, 2))
    createCylinder(watermill, "Wheel", getMat("TreeTrunk"),
        Vector3(0, 2.5, 1.5), Vector3(3.0, 0.3, 3.0))
    -- 水车叶片
    for i = 1, 6 do
        local angle = (i - 1) * 60
        local rad = math.rad(angle)
        local bx = math.cos(rad) * 1.2
        local by = 2.5 + math.sin(rad) * 1.2
        createBox(watermill, "Blade" .. i, getMat("WoodFence"),
            Vector3(bx, by, 1.5), Vector3(0.15, 0.8, 0.25))
    end

    -- 小池塘
    local pondMat = GameConfig.CreateAlphaMaterial(Color(0.25, 0.50, 0.72, 0.6))
    createCylinder(inner, "Pond", pondMat,
        Vector3(-30, -0.1, -60), Vector3(10, 0.15, 10))
    -- 池塘边石头
    for i = 1, 5 do
        local angle = (i / 5) * math.pi * 2
        createRock(inner, "PondRock_" .. i,
            Vector3(-30 + math.cos(angle) * 5.5, 0.1, -60 + math.sin(angle) * 5.5), 0.6)
    end
end

-- ============================================================================
-- 3. 中环区域 (150-300m)
-- ============================================================================

local function buildMidRing(world)
    local mid = world:CreateChild("MidRing")

    -- 东北密林
    rngSeed = 200
    local forestE = mid:CreateChild("ForestEast")
    for i = 1, 45 do
        local angle = seededRange(0.1, 1.4)
        local dist = seededRange(150, 290)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local h = 3.0 + seededRange(0, 3.0)
        local r = 0.8 + seededRange(0, 1.5)
        local leafType = (i % 4 == 0) and "DarkLeaves" or "TreeLeaves"
        createTree(forestE, "FE_" .. i, Vector3(x, 0, z), leafType, h, r)
    end
    createBigRock(mid, "ForestRock1", Vector3(180, 0.5, 180), 3.0, 2.0, 3.0)
    createBigRock(mid, "ForestRock2", Vector3(220, 0.4, 210), 2.5, 1.8, 2.5)
    createBigRock(mid, "ForestRock3", Vector3(200, 0.6, 250), 4.0, 2.5, 3.5)

    -- 西北岩石群
    rngSeed = 300
    local rockCluster = mid:CreateChild("RockCluster")
    local rockDefs = {
        { -200, 180, 5.0, 3.5, 4.5 },
        { -180, 200, 3.5, 4.0, 3.0 },
        { -220, 220, 4.0, 3.0, 5.0 },
        { -190, 240, 6.0, 4.0, 5.5 },
        { -240, 200, 3.0, 2.5, 3.5 },
        { -210, 260, 4.5, 3.5, 4.0 },
        { -170, 170, 2.5, 2.0, 3.0 },
        { -250, 240, 5.5, 4.5, 5.0 },
        { -230, 180, 3.5, 2.5, 4.0 },
        { -200, 160, 4.0, 3.0, 3.5 },
    }
    for i, rd in ipairs(rockDefs) do
        createBigRock(rockCluster, "BigRock_" .. i,
            Vector3(rd[1], rd[4] * 0.3, rd[2]), rd[3], rd[4], rd[5])
    end
    for i = 1, 8 do
        local x = -170 - seededRange(0, 80)
        local z = 160 + seededRange(0, 100)
        createTree(mid, "RockTree_" .. i, Vector3(x, 0, z), "DarkLeaves",
            2.0 + seededRange(0, 1.5), 1.0 + seededRange(0, 0.8))
    end

    -- 西南废墟
    local ruins = mid:CreateChild("Ruins")
    local ruinColor = Color(0.55, 0.50, 0.42, 1.0)
    local ruinMat = getCustomMat(ruinColor)
    createBox(ruins, "RuinWall1", ruinMat,
        Vector3(-200, 1.5, -200), Vector3(12, 3.0, 0.8))
    createBox(ruins, "RuinWall2", ruinMat,
        Vector3(-194, 1.0, -206), Vector3(0.8, 2.0, 12))
    createBox(ruins, "RuinWall3", ruinMat,
        Vector3(-206, 2.0, -206), Vector3(0.8, 4.0, 12))
    for i = 1, 4 do
        local px = -195 - i * 4
        createCylinder(ruins, "RuinPillar_" .. i, ruinMat,
            Vector3(px, 1.5, -195), Vector3(0.6, 3.0, 0.6))
    end
    createCylinder(ruins, "FallenPillar1", ruinMat,
        Vector3(-200, 0.3, -210), Vector3(0.5, 4.0, 0.5))
    local fp = ruins:GetChild("FallenPillar1")
    if fp then fp.rotation = Quaternion(90, Vector3.RIGHT) end
    for i = 1, 6 do
        createRock(ruins, "Rubble_" .. i,
            Vector3(-195 + seededRange(-15, 15), 0.2, -200 + seededRange(-15, 10)),
            0.5 + seededRange(0, 0.8))
    end
    -- 废墟碰撞（SetBox(1,1,1) 因为 node.scale 已经决定了实际大小）
    local rw1 = ruins:GetChild("RuinWall1")
    if rw1 then
        local rb = rw1:CreateComponent("RigidBody"); rb.mass = 0
        local sh = rw1:CreateComponent("CollisionShape"); sh:SetBox(Vector3(1, 1, 1))
    end
    local rw2 = ruins:GetChild("RuinWall2")
    if rw2 then
        local rb = rw2:CreateComponent("RigidBody"); rb.mass = 0
        local sh = rw2:CreateComponent("CollisionShape"); sh:SetBox(Vector3(1, 1, 1))
    end
    local rw3 = ruins:GetChild("RuinWall3")
    if rw3 then
        local rb = rw3:CreateComponent("RigidBody"); rb.mass = 0
        local sh = rw3:CreateComponent("CollisionShape"); sh:SetBox(Vector3(1, 1, 1))
    end

    -- 东南乱石滩 + 枯树
    rngSeed = 400
    local wasteSE = mid:CreateChild("WasteSE")
    for i = 1, 12 do
        local angle = seededRange(-1.4, -0.2)
        local dist = seededRange(160, 280)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local sx = 1.5 + seededRange(0, 3.0)
        local sy = 1.0 + seededRange(0, 2.0)
        local sz = 1.5 + seededRange(0, 3.0)
        createBigRock(wasteSE, "WasteRock_" .. i,
            Vector3(x, sy * 0.3, z), sx, sy, sz)
    end
    local deadLeafColor = Color(0.45, 0.35, 0.22, 1.0)
    local deadLeafMat = getCustomMat(deadLeafColor)
    for i = 1, 8 do
        local angle = seededRange(-1.4, -0.2)
        local dist = seededRange(170, 270)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local h = 2.0 + seededRange(0, 2.5)
        createCylinder(wasteSE, "DeadTree_" .. i, getMat("TreeTrunk"),
            Vector3(x, h / 2, z), Vector3(0.2, h, 0.2))
        createSphere(wasteSE, "DeadCrown_" .. i, deadLeafMat,
            Vector3(x, h + 0.3, z), Vector3(0.8, 0.6, 0.8))
    end

    -- 路标
    local signPosts = {
        { 100, 0 }, { 0, -100 }, { -100, 0 }, { 0, 100 },
    }
    for i, sp in ipairs(signPosts) do
        createBox(mid, "SignPost_" .. i, getMat("WoodFence"),
            Vector3(sp[1], 1.0, sp[2]), Vector3(1.0, 0.7, 0.1))
        createCylinder(mid, "SignPole_" .. i, getMat("TreeTrunk"),
            Vector3(sp[1], 0.5, sp[2]), Vector3(0.06, 1.0, 0.06))
    end

    -- 中环补充树木
    rngSeed = 500
    for i = 1, 30 do
        local angle = seededRange(0, 6.28)
        local dist = seededRange(150, 300)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local h = 2.0 + seededRange(0, 2.5)
        local r = 1.0 + seededRange(0, 1.2)
        local leafType = (i % 3 == 0) and "DarkLeaves" or "TreeLeaves"
        createTree(mid, "MidTree_" .. i, Vector3(x, 0, z), leafType, h, r)
    end
end

-- ============================================================================
-- 4. 外环区域 (300-390m)
-- ============================================================================

local function buildOuterRing(world)
    local outer = world:CreateChild("OuterRing")

    -- 荒野岩石
    rngSeed = 600
    for i = 1, 20 do
        local angle = seededRange(0, 6.28)
        local dist = seededRange(300, 380)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local sx = 1.5 + seededRange(0, 3.5)
        local sy = 1.0 + seededRange(0, 2.5)
        local sz = 1.5 + seededRange(0, 3.5)
        createBigRock(outer, "OutRock_" .. i,
            Vector3(x, sy * 0.3, z), sx, sy, sz)
    end

    -- 枯树
    rngSeed = 700
    local deadColor = Color(0.40, 0.32, 0.20, 1.0)
    local deadMat = getCustomMat(deadColor)
    for i = 1, 15 do
        local angle = seededRange(0, 6.28)
        local dist = seededRange(310, 385)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local h = 1.5 + seededRange(0, 2.0)
        createCylinder(outer, "OutDead_" .. i, getMat("TreeTrunk"),
            Vector3(x, h / 2, z), Vector3(0.15, h, 0.15))
        createSphere(outer, "OutDeadC_" .. i, deadMat,
            Vector3(x, h + 0.2, z), Vector3(0.6, 0.4, 0.6))
    end

    -- 残破石墙
    local wallDefs = {
        { 320, 0, 0, 20, 3.5 },
        { -330, 50, 90, 25, 3.0 },
        { 0, -340, 90, 18, 4.0 },
        { 50, 350, 0, 22, 3.5 },
    }
    local wallMat = getCustomMat(Color(0.50, 0.45, 0.38, 1.0))
    for i, wd in ipairs(wallDefs) do
        local node = createBox(outer, "OutWall_" .. i, wallMat,
            Vector3(wd[1], wd[5] / 2, wd[2]), Vector3(2.0, wd[5], wd[4]))
        if wd[3] ~= 0 then
            node.rotation = Quaternion(wd[3], Vector3.UP)
        end
        local rb = node:CreateComponent("RigidBody"); rb.mass = 0
        local sh = node:CreateComponent("CollisionShape"); sh:SetBox(Vector3(1, 1, 1))
    end
end

-- ============================================================================
-- 5. 边界墙
-- ============================================================================

local function buildBoundaryWalls(world)
    local bounds = world:CreateChild("Boundary")
    local boundaryColor = Color(0.25, 0.22, 0.30, 1.0)
    local boundaryMat = getCustomMat(boundaryColor)
    local wallLength = MAP_HALF * 2

    local wn = createBox(bounds, "WallNorth", boundaryMat,
        Vector3(0, WALL_HEIGHT / 2, BOUNDARY_DIST),
        Vector3(wallLength, WALL_HEIGHT, WALL_THICK))
    local ws = createBox(bounds, "WallSouth", boundaryMat,
        Vector3(0, WALL_HEIGHT / 2, -BOUNDARY_DIST),
        Vector3(wallLength, WALL_HEIGHT, WALL_THICK))
    local we = createBox(bounds, "WallEast", boundaryMat,
        Vector3(BOUNDARY_DIST, WALL_HEIGHT / 2, 0),
        Vector3(WALL_THICK, WALL_HEIGHT, wallLength))
    local ww = createBox(bounds, "WallWest", boundaryMat,
        Vector3(-BOUNDARY_DIST, WALL_HEIGHT / 2, 0),
        Vector3(WALL_THICK, WALL_HEIGHT, wallLength))

    for _, wallNode in ipairs({ wn, ws, we, ww }) do
        local rb = wallNode:CreateComponent("RigidBody")
        rb.mass = 0
        local shape = wallNode:CreateComponent("CollisionShape")
        shape:SetBox(Vector3(1, 1, 1))
    end

    local glowMat = GameConfig.CreateEmissiveMaterial(Color(0.4, 0.3, 0.7, 1.0), 2.0)
    createBox(bounds, "GlowN", glowMat,
        Vector3(0, WALL_HEIGHT + 0.2, BOUNDARY_DIST), Vector3(wallLength, 0.4, WALL_THICK + 0.5))
    createBox(bounds, "GlowS", glowMat,
        Vector3(0, WALL_HEIGHT + 0.2, -BOUNDARY_DIST), Vector3(wallLength, 0.4, WALL_THICK + 0.5))
    createBox(bounds, "GlowE", glowMat,
        Vector3(BOUNDARY_DIST, WALL_HEIGHT + 0.2, 0), Vector3(WALL_THICK + 0.5, 0.4, wallLength))
    createBox(bounds, "GlowW", glowMat,
        Vector3(-BOUNDARY_DIST, WALL_HEIGHT + 0.2, 0), Vector3(WALL_THICK + 0.5, 0.4, wallLength))

    local pillarMat = GameConfig.CreateEmissiveMaterial(Color(0.5, 0.35, 0.8, 1.0), 3.0)
    local corners = {
        { BOUNDARY_DIST, BOUNDARY_DIST },
        { BOUNDARY_DIST, -BOUNDARY_DIST },
        { -BOUNDARY_DIST, BOUNDARY_DIST },
        { -BOUNDARY_DIST, -BOUNDARY_DIST },
    }
    for i, c in ipairs(corners) do
        createCylinder(bounds, "CornerPillar_" .. i, pillarMat,
            Vector3(c[1], WALL_HEIGHT / 2 + 2, c[2]),
            Vector3(1.5, WALL_HEIGHT + 4, 1.5))
    end

    print("[VillageBuilder] 边界墙已构建 (±" .. BOUNDARY_DIST .. "m)")
end

-- ============================================================================
-- 主构建函数
-- ============================================================================

---@param scene Scene
function VillageBuilder.Build(scene)
    local world = scene:CreateChild("Village")

    -- 大地面 (800×800)
    local groundSize = MAP_HALF * 2
    local ground = createBox(world, "Ground", getMat("Grass"),
        Vector3(0, -0.25, 0), Vector3(groundSize, 0.5, groundSize))
    ground:GetComponent("StaticModel").castShadows = false

    buildVillageCore(world)
    buildInnerRing(world)
    buildMidRing(world)
    buildOuterRing(world)
    buildBoundaryWalls(world)

    print("[VillageBuilder] 大世界构建完成 (" .. groundSize .. "x" .. groundSize .. "m)")
    return world
end

-- ============================================================================
-- 光照设置
-- ============================================================================

---@param scene Scene
function VillageBuilder.SetupLighting(scene)
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
    if lightGroupFile then
        local lightGroup = scene:CreateChild("LightGroup")
        lightGroup:LoadXML(lightGroupFile:GetRoot())
        print("[VillageBuilder] 使用 Daytime LightGroup")
    else
        local lightNode = scene:CreateChild("DirectionalLight")
        lightNode.rotation = Quaternion(45, 30, 0)
        local light = lightNode:CreateComponent("Light")
        light.lightType = LIGHT_DIRECTIONAL
        light.color = Color(1.0, 0.95, 0.85, 1.0)
        light.brightness = 1.2
        light.castShadows = true
        light.shadowBias = BiasParameters(0.00025, 0.5)
        light.shadowCascade = CascadeParameters(10.0, 30.0, 80.0, 200.0, 0.8)
        print("[VillageBuilder] 使用降级手动灯光")
    end
end

-- ============================================================================
-- 物理设置
-- ============================================================================

---@param scene Scene
function VillageBuilder.SetupPhysics(scene)
    local physicsWorld = scene:GetComponent("PhysicsWorld")
    if not physicsWorld then
        physicsWorld = scene:CreateComponent("PhysicsWorld")
    end
    physicsWorld:SetGravity(Vector3(0, GameConfig.Player.Gravity, 0))
    physicsWorld:SetFps(60)
    physicsWorld:SetMaxSubSteps(3)
    physicsWorld:SetNumIterations(8)
    physicsWorld:SetInterpolation(true)

    local groundSize = MAP_HALF * 2

    local groundNode = scene:GetChild("Village"):GetChild("Ground")
    if groundNode then
        local rb = groundNode:CreateComponent("RigidBody")
        rb.mass = 0
        rb.collisionLayer = CollisionLayerStatic
        local shape = groundNode:CreateComponent("CollisionShape")
        shape:SetBox(Vector3(1, 1, 1))
    end

    -- 桥梁碰撞体（已移除）

    print("[VillageBuilder] 物理系统初始化完成 (地面 " .. groundSize .. "x" .. groundSize .. "m)")
end

---@param dt number
function VillageBuilder.Update(dt)
    updateDoorAnimations(dt)
end

---@param doorPivotNode Node
function VillageBuilder.ToggleDoor(doorPivotNode)
    toggleDoor(doorPivotNode)
end

---@return number
function VillageBuilder.GetMapHalf()
    return MAP_HALF
end

---@return number
function VillageBuilder.GetBoundaryDist()
    return BOUNDARY_DIST
end

return VillageBuilder
