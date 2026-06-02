-- ============================================================================
-- AffixDatabase.lua — 词条数据库（168模板 × 6品质 = 1008词条）
-- 词条品质独立于物品品级，有自己的6级体系
-- ============================================================================

local AffixDatabase = {}

-- ============================================================================
-- 词条品质等级（与物品品级分离）
-- ============================================================================

AffixDatabase.QualityTiers = {
    [1] = { name = "普通", color = {180,180,180,255}, weight = 80   },
    [2] = { name = "中级", color = {100,210,100,255}, weight = 30   },
    [3] = { name = "高级", color = { 80,140,255,255}, weight = 15   },
    [4] = { name = "顶级", color = {200,120,255,255}, weight = 10   },
    [5] = { name = "史诗", color = {255,100, 50,255}, weight = 3    },
    [6] = { name = "至臻", color = {255,215,  0,255}, weight = 0.1  },
}

--- 品质后缀
local Q_SUFFIX = { "·凡", "·良", "·精", "·极", "·圣", "·臻" }

-- ============================================================================
-- 属性单位映射
-- ============================================================================

local STAT_UNITS = {
    damagePct   = "%",
    critPct     = "%",
    atkSpdPct   = "%",
    maxHP       = "",
    cooldownPct = "%",
    moveSpdPct  = "%",
    rangePct    = "%",
}

local STAT_NAMES = {
    damagePct   = "伤害",
    critPct     = "暴击",
    atkSpdPct   = "攻速",
    maxHP       = "生命",
    cooldownPct = "冷却缩减",
    moveSpdPct  = "移速",
    rangePct    = "范围",
}

-- ============================================================================
-- 168 词条模板
-- 格式: {id, displayName, stat, category, {普通,中级,高级,顶级,史诗,至臻}}
-- ============================================================================

local TEMPLATES = {
    -- ===================== 攻击类 (35) =====================
    -- damagePct 伤害 (20)
    {"atk_001","锋芒",  "damagePct","attack",{1,3,6,10,16,25}},
    {"atk_002","破甲",  "damagePct","attack",{1,2,5,9,14,22}},
    {"atk_003","猛击",  "damagePct","attack",{2,4,7,11,17,26}},
    {"atk_004","蛮力",  "damagePct","attack",{1,3,5,9,15,23}},
    {"atk_005","凶煞",  "damagePct","attack",{2,3,6,10,15,24}},
    {"atk_006","嗜血",  "damagePct","attack",{1,3,6,11,17,27}},
    {"atk_007","杀意",  "damagePct","attack",{1,2,5,8,13,21}},
    {"atk_008","怒火",  "damagePct","attack",{2,4,7,12,18,28}},
    {"atk_009","战意",  "damagePct","attack",{1,3,5,9,14,22}},
    {"atk_010","斗志",  "damagePct","attack",{2,3,6,10,16,25}},
    {"atk_011","霸气",  "damagePct","attack",{1,4,7,11,17,26}},
    {"atk_012","灭世",  "damagePct","attack",{2,4,8,13,19,29}},
    {"atk_013","屠龙",  "damagePct","attack",{2,5,8,12,18,28}},
    {"atk_014","伐魔",  "damagePct","attack",{1,3,6,10,16,24}},
    {"atk_015","诛邪",  "damagePct","attack",{1,3,5,9,14,23}},
    {"atk_016","天罚",  "damagePct","attack",{2,4,7,11,17,27}},
    {"atk_017","裁决",  "damagePct","attack",{1,3,6,10,16,25}},
    {"atk_018","狂暴",  "damagePct","attack",{2,5,8,13,19,30}},
    {"atk_019","暴虐",  "damagePct","attack",{2,4,7,12,18,28}},
    {"atk_020","凶猛",  "damagePct","attack",{1,3,6,10,15,24}},
    -- critPct 暴击 (5)
    {"atk_021","精准",  "critPct",  "attack",{1,2,3,5,8,12}},
    {"atk_022","会心",  "critPct",  "attack",{1,2,4,6,9,14}},
    {"atk_023","致命",  "critPct",  "attack",{1,1,3,5,8,13}},
    {"atk_024","要害",  "critPct",  "attack",{1,2,4,6,9,13}},
    {"atk_025","穿心",  "critPct",  "attack",{1,2,3,5,8,12}},
    -- atkSpdPct 攻速 (5)
    {"atk_026","迅捷",  "atkSpdPct","attack",{1,2,4,7,11,16}},
    {"atk_027","疾风",  "atkSpdPct","attack",{1,3,5,8,12,18}},
    {"atk_028","连击",  "atkSpdPct","attack",{1,2,3,6,10,15}},
    {"atk_029","急速",  "atkSpdPct","attack",{1,3,5,7,11,17}},
    {"atk_030","闪袭",  "atkSpdPct","attack",{1,2,4,7,11,16}},
    -- rangePct 范围 (5)
    {"atk_031","延伸",  "rangePct", "attack",{1,2,4,7,11,16}},
    {"atk_032","广域",  "rangePct", "attack",{1,3,5,8,12,18}},
    {"atk_033","贯穿",  "rangePct", "attack",{1,2,4,6,10,15}},
    {"atk_034","波及",  "rangePct", "attack",{1,3,5,8,12,17}},
    {"atk_035","覆盖",  "rangePct", "attack",{1,2,4,7,11,16}},

    -- ===================== 防御类 (28) =====================
    {"def_001","坚韧",  "maxHP",    "defense",{3,7,12,20,32,50}},
    {"def_002","生机",  "maxHP",    "defense",{4,9,16,26,42,65}},
    {"def_003","不屈",  "maxHP",    "defense",{5,10,18,28,45,70}},
    {"def_004","铁壁",  "maxHP",    "defense",{3,8,14,22,36,55}},
    {"def_005","磐石",  "maxHP",    "defense",{4,8,15,24,38,58}},
    {"def_006","龙鳞",  "maxHP",    "defense",{5,11,19,30,48,72}},
    {"def_007","神盾",  "maxHP",    "defense",{4,9,16,26,40,62}},
    {"def_008","天佑",  "maxHP",    "defense",{3,7,13,21,34,52}},
    {"def_009","护体",  "maxHP",    "defense",{3,8,14,23,37,56}},
    {"def_010","金刚",  "maxHP",    "defense",{5,10,18,29,46,68}},
    {"def_011","荆棘",  "maxHP",    "defense",{3,7,12,20,32,50}},
    {"def_012","再生",  "maxHP",    "defense",{4,9,15,25,40,60}},
    {"def_013","回春",  "maxHP",    "defense",{4,8,14,23,36,55}},
    {"def_014","续命",  "maxHP",    "defense",{5,10,17,27,43,66}},
    {"def_015","不灭",  "maxHP",    "defense",{5,11,19,30,48,72}},
    {"def_016","火抗",  "maxHP",    "defense",{3,7,13,21,33,51}},
    {"def_017","冰抗",  "maxHP",    "defense",{3,7,13,21,33,51}},
    {"def_018","雷抗",  "maxHP",    "defense",{3,7,13,21,33,51}},
    {"def_019","毒抗",  "maxHP",    "defense",{3,7,12,20,32,50}},
    {"def_020","暗抗",  "maxHP",    "defense",{3,7,12,20,32,50}},
    {"def_021","圣抗",  "maxHP",    "defense",{3,8,14,22,35,54}},
    {"def_022","万抗",  "maxHP",    "defense",{4,9,15,24,38,58}},
    {"def_023","格挡",  "maxHP",    "defense",{3,8,14,23,37,56}},
    {"def_024","闪避",  "maxHP",    "defense",{4,9,16,26,41,63}},
    {"def_025","坚守",  "maxHP",    "defense",{3,7,13,21,34,52}},
    {"def_026","守护",  "maxHP",    "defense",{5,10,17,28,44,67}},
    {"def_027","壁垒",  "maxHP",    "defense",{4,9,15,25,40,62}},
    {"def_028","庇护",  "maxHP",    "defense",{4,8,14,23,36,55}},

    -- ===================== 机动类 (18) =====================
    {"mob_001","飞步",  "moveSpdPct","mobility",{1,1,2,3,5,8}},
    {"mob_002","轻功",  "moveSpdPct","mobility",{1,2,3,4,6,9}},
    {"mob_003","疾行",  "moveSpdPct","mobility",{1,1,2,4,6,10}},
    {"mob_004","神行",  "moveSpdPct","mobility",{1,2,3,5,7,11}},
    {"mob_005","追风",  "moveSpdPct","mobility",{1,1,2,3,5,8}},
    {"mob_006","踏雪",  "moveSpdPct","mobility",{1,2,3,4,6,9}},
    {"mob_007","凌波",  "moveSpdPct","mobility",{1,1,3,4,6,10}},
    {"mob_008","缩地",  "moveSpdPct","mobility",{1,2,3,5,7,11}},
    {"mob_009","瞬步",  "moveSpdPct","mobility",{1,2,3,4,6,9}},
    {"mob_010","御风",  "moveSpdPct","mobility",{1,1,2,3,5,8}},
    {"mob_011","灵动",  "moveSpdPct","mobility",{1,2,3,5,7,10}},
    {"mob_012","身法",  "moveSpdPct","mobility",{1,1,2,4,6,9}},
    {"mob_013","流影",  "moveSpdPct","mobility",{1,2,3,4,6,10}},
    {"mob_014","幻步",  "moveSpdPct","mobility",{1,1,2,3,5,8}},
    {"mob_015","腾云",  "moveSpdPct","mobility",{1,2,3,5,7,11}},
    {"mob_016","遁地",  "moveSpdPct","mobility",{1,1,2,4,6,9}},
    {"mob_017","逐日",  "moveSpdPct","mobility",{1,2,3,4,6,10}},
    {"mob_018","追月",  "moveSpdPct","mobility",{1,1,2,3,5,8}},

    -- ===================== 技能类 (25) =====================
    -- cooldownPct (15)
    {"skl_001","冥想",  "cooldownPct","skill",{1,2,3,5,8,12}},
    {"skl_002","顿悟",  "cooldownPct","skill",{1,2,4,6,9,14}},
    {"skl_003","流转",  "cooldownPct","skill",{1,1,3,5,7,11}},
    {"skl_004","轮回",  "cooldownPct","skill",{1,2,4,6,9,13}},
    {"skl_005","时停",  "cooldownPct","skill",{1,2,3,5,8,12}},
    {"skl_006","加速",  "cooldownPct","skill",{1,2,4,6,9,14}},
    {"skl_007","超频",  "cooldownPct","skill",{1,3,5,7,10,15}},
    {"skl_008","共鸣",  "cooldownPct","skill",{1,2,3,5,8,12}},
    {"skl_009","蓄力",  "cooldownPct","skill",{1,2,4,6,9,13}},
    {"skl_010","复刻",  "cooldownPct","skill",{1,1,3,5,7,11}},
    {"skl_011","熟练",  "cooldownPct","skill",{1,2,3,5,8,12}},
    {"skl_012","精通",  "cooldownPct","skill",{1,2,4,6,9,14}},
    {"skl_013","领悟",  "cooldownPct","skill",{1,1,3,5,8,12}},
    {"skl_014","感应",  "cooldownPct","skill",{1,2,4,6,9,13}},
    {"skl_015","洞察",  "cooldownPct","skill",{1,2,3,5,8,12}},
    -- rangePct (5)
    {"skl_016","延展",  "rangePct","skill",  {1,2,4,7,11,16}},
    {"skl_017","扩散",  "rangePct","skill",  {1,3,5,8,12,18}},
    {"skl_018","远射",  "rangePct","skill",  {1,2,3,6,10,15}},
    {"skl_019","吸引",  "rangePct","skill",  {1,3,5,7,11,17}},
    {"skl_020","漩涡",  "rangePct","skill",  {1,2,4,7,11,16}},
    -- atkSpdPct (5)
    {"skl_021","专注",  "atkSpdPct","skill", {1,2,4,7,11,16}},
    {"skl_022","奥义",  "atkSpdPct","skill", {1,3,5,8,12,18}},
    {"skl_023","悟道",  "atkSpdPct","skill", {1,2,3,6,10,15}},
    {"skl_024","参悟",  "atkSpdPct","skill", {1,2,4,7,11,16}},
    {"skl_025","开窍",  "atkSpdPct","skill", {1,3,5,8,12,17}},

    -- ===================== 元素类 (32) =====================
    -- 火 (5)
    {"elm_001","焚天",  "damagePct","element",{2,4,7,12,18,28}},
    {"elm_002","炎爆",  "damagePct","element",{1,3,6,10,16,25}},
    {"elm_003","灼热",  "damagePct","element",{1,3,5,9,14,22}},
    {"elm_004","燎原",  "damagePct","element",{2,4,7,11,17,26}},
    {"elm_005","凤凰",  "damagePct","element",{2,5,8,13,19,30}},
    -- 冰 (5)
    {"elm_006","冰封",  "damagePct","element",{1,3,6,10,15,24}},
    {"elm_007","霜冻",  "damagePct","element",{1,3,5,9,14,22}},
    {"elm_008","极寒",  "damagePct","element",{2,4,7,11,17,27}},
    {"elm_009","雪崩",  "damagePct","element",{2,4,8,12,18,28}},
    {"elm_010","冰晶",  "damagePct","element",{1,3,6,10,16,25}},
    -- 雷 (5)
    {"elm_011","惊雷",  "damagePct","element",{2,4,7,12,18,28}},
    {"elm_012","闪击",  "damagePct","element",{1,3,6,10,16,25}},
    {"elm_013","电弧",  "damagePct","element",{1,3,5,9,15,23}},
    {"elm_014","雷暴",  "damagePct","element",{2,5,8,13,19,29}},
    {"elm_015","天雷",  "damagePct","element",{2,4,7,11,17,26}},
    -- 毒 (5)
    {"elm_016","蛊毒",  "damagePct","element",{1,3,6,10,15,24}},
    {"elm_017","腐蚀",  "damagePct","element",{2,4,7,11,17,26}},
    {"elm_018","瘟疫",  "damagePct","element",{1,3,5,9,14,22}},
    {"elm_019","淬毒",  "damagePct","element",{2,4,7,12,18,27}},
    {"elm_020","毒雾",  "damagePct","element",{1,3,6,10,16,25}},
    -- 暗 (5)
    {"elm_021","冥蚀",  "damagePct","element",{2,4,7,11,17,27}},
    {"elm_022","幽噬",  "damagePct","element",{1,3,6,10,16,25}},
    {"elm_023","虚无",  "damagePct","element",{1,3,5,9,15,23}},
    {"elm_024","吞噬",  "damagePct","element",{2,5,8,12,18,28}},
    {"elm_025","湮灭",  "damagePct","element",{2,4,8,13,19,30}},
    -- 圣 (5) → maxHP
    {"elm_026","净化",  "maxHP",    "element",{4,9,15,24,38,58}},
    {"elm_027","神圣",  "maxHP",    "element",{5,10,17,27,43,66}},
    {"elm_028","天恩",  "maxHP",    "element",{3,8,14,23,37,56}},
    {"elm_029","圣裁",  "maxHP",    "element",{4,9,16,26,41,63}},
    {"elm_030","救赎",  "maxHP",    "element",{5,11,18,29,46,70}},
    -- 风/自然 (2) → atkSpdPct
    {"elm_031","风暴",  "atkSpdPct","element",{1,3,5,8,12,18}},
    {"elm_032","旋风",  "atkSpdPct","element",{1,2,4,7,11,16}},

    -- ===================== 特殊类 (30) =====================
    -- 财运 (5) → critPct
    {"spc_001","聚财",  "critPct",  "special",{1,2,3,5,8,12}},
    {"spc_002","点金",  "critPct",  "special",{1,2,4,6,9,14}},
    {"spc_003","宝运",  "critPct",  "special",{1,1,3,5,7,11}},
    {"spc_004","财神",  "critPct",  "special",{1,2,4,6,9,13}},
    {"spc_005","满贯",  "critPct",  "special",{1,2,3,5,8,12}},
    -- 智慧 (5) → cooldownPct
    {"spc_006","悟性",  "cooldownPct","special",{1,2,3,5,8,12}},
    {"spc_007","智慧",  "cooldownPct","special",{1,2,4,6,9,14}},
    {"spc_008","明智",  "cooldownPct","special",{1,1,3,5,7,11}},
    {"spc_009","博学",  "cooldownPct","special",{1,2,4,6,9,13}},
    {"spc_010","渊博",  "cooldownPct","special",{1,2,3,5,8,12}},
    -- 命运 (5) → critPct
    {"spc_011","吸魂",  "critPct",  "special",{1,2,4,6,9,13}},
    {"spc_012","噬灵",  "critPct",  "special",{1,2,3,5,8,12}},
    {"spc_013","天命",  "critPct",  "special",{1,1,3,5,7,11}},
    {"spc_014","气运",  "critPct",  "special",{1,2,4,6,9,14}},
    {"spc_015","鸿运",  "critPct",  "special",{1,2,3,5,8,12}},
    -- 杀伐 (5) → damagePct
    {"spc_016","杀气",  "damagePct","special",{1,3,6,10,16,25}},
    {"spc_017","夺魂",  "damagePct","special",{2,4,7,11,17,26}},
    {"spc_018","摄魂",  "damagePct","special",{1,3,5,9,14,22}},
    {"spc_019","镇魂",  "damagePct","special",{2,4,7,12,18,27}},
    {"spc_020","封魂",  "damagePct","special",{1,3,6,10,15,24}},
    -- 生命 (5) → maxHP
    {"spc_021","吸血",  "maxHP",    "special",{4,9,15,24,38,58}},
    {"spc_022","汲取",  "maxHP",    "special",{3,8,14,22,36,55}},
    {"spc_023","虹吸",  "maxHP",    "special",{5,10,17,27,43,66}},
    {"spc_024","夺命",  "maxHP",    "special",{4,9,16,26,41,63}},
    {"spc_025","嗜命",  "maxHP",    "special",{3,7,13,21,34,52}},
    -- 超越 (5) → rangePct
    {"spc_026","破境",  "rangePct", "special",{1,2,4,7,11,16}},
    {"spc_027","超越",  "rangePct", "special",{1,3,5,8,12,18}},
    {"spc_028","觉醒",  "rangePct", "special",{1,2,4,6,10,15}},
    {"spc_029","天赋",  "rangePct", "special",{1,3,5,7,11,17}},
    {"spc_030","神启",  "rangePct", "special",{1,2,4,7,11,16}},
}

-- ============================================================================
-- 从模板生成全部 1008 词条
-- ============================================================================

AffixDatabase.All      = {}   -- 全部词条数组
AffixDatabase.ById     = {}   -- id → affix
AffixDatabase.ByTier   = { {},{},{},{},{},{} }
AffixDatabase.ByStat   = {}
AffixDatabase.ByCat    = {}
AffixDatabase.Templates = TEMPLATES

for _, t in ipairs(TEMPLATES) do
    for tier = 1, 6 do
        local id = t[1] .. "_t" .. tier
        local affix = {
            id         = id,
            templateId = t[1],
            name       = t[2] .. Q_SUFFIX[tier],
            baseName   = t[2],
            stat       = t[3],
            statName   = STAT_NAMES[t[3]] or t[3],
            unit       = STAT_UNITS[t[3]] or "",
            category   = t[4],
            value      = t[5][tier],
            tier       = tier,
            tierName   = AffixDatabase.QualityTiers[tier].name,
        }
        table.insert(AffixDatabase.All, affix)
        AffixDatabase.ById[id] = affix
        table.insert(AffixDatabase.ByTier[tier], affix)

        if not AffixDatabase.ByStat[affix.stat] then
            AffixDatabase.ByStat[affix.stat] = {}
        end
        table.insert(AffixDatabase.ByStat[affix.stat], affix)

        if not AffixDatabase.ByCat[affix.category] then
            AffixDatabase.ByCat[affix.category] = {}
        end
        table.insert(AffixDatabase.ByCat[affix.category], affix)
    end
end

-- ============================================================================
-- 查询 API
-- ============================================================================

--- 获取品质等级信息
---@param tier number 1~6
---@return table
function AffixDatabase.GetQualityTier(tier)
    return AffixDatabase.QualityTiers[tier] or AffixDatabase.QualityTiers[1]
end

--- 获取品质名称
---@param tier number
---@return string
function AffixDatabase.GetQualityName(tier)
    local qt = AffixDatabase.QualityTiers[tier]
    return qt and qt.name or "普通"
end

--- 获取品质颜色
---@param tier number
---@return table
function AffixDatabase.GetQualityColor(tier)
    local qt = AffixDatabase.QualityTiers[tier]
    return qt and qt.color or {180,180,180,255}
end

--- 格式化词条显示文本
---@param affix table {name, value, unit, tier, ...}
---@return string
function AffixDatabase.FormatAffix(affix)
    if not affix then return "" end
    local prefix = "+"
    local val = affix.value or 0
    local unit = affix.unit or ""
    if unit == "%" then
        return prefix .. val .. "% " .. (affix.statName or affix.name or "")
    else
        return prefix .. val .. " " .. (affix.statName or affix.name or "")
    end
end

--- 格式化词条显示（带品质名）
---@param affix table
---@return string
function AffixDatabase.FormatAffixFull(affix)
    if not affix then return "" end
    local base = AffixDatabase.FormatAffix(affix)
    return "[" .. (affix.tierName or "普通") .. "] " .. (affix.name or "") .. " " .. base
end

--- 获取模板总数
---@return number
function AffixDatabase.GetTemplateCount()
    return #TEMPLATES
end

--- 获取词条总数
---@return number
function AffixDatabase.GetTotalCount()
    return #AffixDatabase.All
end

print("[AffixDatabase] 加载完成: " .. #TEMPLATES .. " 模板, "
    .. #AffixDatabase.All .. " 词条")

return AffixDatabase
