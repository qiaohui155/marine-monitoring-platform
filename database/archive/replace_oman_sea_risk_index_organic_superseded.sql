-- Replace the previous large risk polygons with smaller, organic-looking
-- simulated marine zones.  No ship_position or ship_track data is changed.
--
-- Design principle: use compact ecological patches and narrow port corridors;
-- never use one large opaque polygon to cover the whole Arabian Sea.

ALTER TABLE sea_risk_index
  ADD COLUMN IF NOT EXISTS fill_hex varchar(7),
  ADD COLUMN IF NOT EXISTS display_opacity smallint;

DELETE FROM sea_risk_index;

INSERT INTO sea_risk_index
  (risk_level, coefficient, area_name, basis, draw_order, fill_hex, display_opacity, geom)
VALUES
  -- Level 1: highest ecological value, compact near-shore marine patches.
  ('一级核心敏感区', 2.0, '穆桑代姆珊瑚礁', '生态保护价值最高', 60, '#D73027', 48,
   ST_Multi(ST_Union(
     ST_Buffer(ST_SetSRID(ST_MakePoint(56.30,26.16),4326)::geography, 13500)::geometry,
     ST_Buffer(ST_SetSRID(ST_MakePoint(56.49,26.10),4326)::geography, 10500)::geometry))),
  ('一级核心敏感区', 2.0, '马西拉岛海龟产卵近海区', '生态保护价值最高', 60, '#D73027', 48,
   ST_Multi(ST_Union(
     ST_Buffer(ST_SetSRID(ST_MakePoint(59.12,20.60),4326)::geography, 17000)::geometry,
     ST_Buffer(ST_SetSRID(ST_MakePoint(59.20,20.42),4326)::geography, 11000)::geometry))),
  ('一级核心敏感区', 2.0, '库鲁姆红树林近海区', '生态保护价值最高', 60, '#D73027', 48,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(58.60,23.66),4326)::geography, 9000)::geometry)),

  -- Level 2: protected-island and whale-activity water patches.
  ('二级高度敏感区', 1.8, '哈拉尼亚特群岛海域', '生物多样性高', 50, '#FC8D59', 42,
   ST_Multi(ST_Union(
     ST_Buffer(ST_SetSRID(ST_MakePoint(55.83,17.46),4326)::geography, 19000)::geometry,
     ST_Buffer(ST_SetSRID(ST_MakePoint(56.02,17.35),4326)::geography, 14000)::geometry))),
  ('二级高度敏感区', 1.8, '佐法尔鲸类活动海域', '生物多样性高', 50, '#FC8D59', 42,
   ST_Multi(ST_Union(
     ST_Buffer(ST_SetSRID(ST_MakePoint(54.90,16.96),4326)::geography, 22000)::geometry,
     ST_Buffer(ST_SetSRID(ST_MakePoint(55.22,17.12),4326)::geography, 16000)::geometry))),
  ('二级高度敏感区', 1.8, '拉斯哈德海洋保护近海区', '生物多样性高', 50, '#FC8D59', 42,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(60.05,22.53),4326)::geography, 18000)::geometry)),

  -- Level 3: Muscat tourist coast and coastal economic area.
  ('三级重要生态区', 1.5, '马斯喀特旅游海湾', '人口和经济价值高', 40, '#FEE08B', 36,
   ST_Multi(ST_Union(
     ST_Buffer(ST_SetSRID(ST_MakePoint(58.76,23.70),4326)::geography, 15000)::geometry,
     ST_Buffer(ST_SetSRID(ST_MakePoint(58.93,23.62),4326)::geography, 11000)::geometry))),
  ('三级重要生态区', 1.5, '苏尔旅游近海区', '人口和经济价值高', 40, '#FEE08B', 36,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(59.55,22.52),4326)::geography, 14000)::geometry)),

  -- Level 4: resource-sensitive fishing grounds.
  ('四级资源敏感区', 1.2, '苏哈尔近海渔场', '渔业资源', 30, '#91CF60', 32,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(56.98,24.45),4326)::geography, 17000)::geometry)),
  ('四级资源敏感区', 1.2, '杜库姆近海渔场', '渔业资源', 30, '#91CF60', 32,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(57.96,19.74),4326)::geography, 19000)::geometry)),
  ('四级资源敏感区', 1.2, '塞拉莱近海渔场', '渔业资源', 30, '#91CF60', 32,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(54.24,16.83),4326)::geography, 18500)::geometry)),

  -- Level 5: narrow shipping corridors; these read as routes, not broad blocks.
  ('五级交通敏感区', 1.0, '苏尔港进出航道', '运输风险', 20, '#4575B4', 35,
   ST_Multi(ST_Buffer(ST_GeomFromText('LINESTRING(60.03 22.62,59.82 22.57,59.60 22.52,59.42 22.48)',4326)::geography, 6500)::geometry)),
  ('五级交通敏感区', 1.0, '杜库姆港进出航道', '运输风险', 20, '#4575B4', 35,
   ST_Multi(ST_Buffer(ST_GeomFromText('LINESTRING(58.20 19.88,58.02 19.82,57.84 19.75,57.70 19.70)',4326)::geography, 7000)::geometry)),
  ('五级交通敏感区', 1.0, '塞拉莱港进出航道', '运输风险', 20, '#4575B4', 35,
   ST_Multi(ST_Buffer(ST_GeomFromText('LINESTRING(54.55 16.86,54.39 16.84,54.24 16.82,54.08 16.79)',4326)::geography, 7000)::geometry)),

  -- Level 6: only a few small, pale reference patches in deep water.
  ('六级低敏区域', 0.5, '阿曼外海深水参考区 A', '生态影响较小', 10, '#BFD3E6', 14,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(61.55,21.20),4326)::geography, 25000)::geometry)),
  ('六级低敏区域', 0.5, '阿曼外海深水参考区 B', '生态影响较小', 10, '#BFD3E6', 14,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(62.90,20.25),4326)::geography, 28000)::geometry)),
  ('六级低敏区域', 0.5, '阿曼外海深水参考区 C', '生态影响较小', 10, '#BFD3E6', 14,
   ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(60.80,18.70),4326)::geography, 26000)::geometry));

-- QGIS styling: categorize on risk_level, then use the fill_hex values above.
-- Use low opacity for levels 4--6; keep this layer below vessels and tracks.
