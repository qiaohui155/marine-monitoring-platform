# Oman Marine Monitoring Dashboard

This frontend is the browser-based operational screen for the local Oman marine monitoring platform. It uses MapLibre GL JS and reads all business data from the local FastAPI service at `http://127.0.0.1:8000`.

## Current functions

- Live AIS vessel positions with course-oriented symbols
- Overview vessel symbols below zoom 9 and type colors at detailed zoom levels
- Vessel name and MMSI search
- Vessel type filters and layer controls
- Searchable historical-track vessel catalog with one-vessel-at-a-time map display and a clear-selection action
- Pollution events, sea-risk areas, suspected vessels, and warning areas
- Dynamic dashboard statistics, risk signals, incident status, and recent events
- Automatic API refresh every 5 seconds
- Stable map selection: small pointer movement during a click no longer pans the map, and double-click zoom is disabled
- Smooth position transitions between successive AIS coordinates while retaining the latest reported course
- Centered, light vessel-detail windows with draggable headers and automatic navigation-status classification
- Four switchable basemaps, including pure satellite imagery and a satellite hybrid with boundaries and place labels
- Automatic default basemap by vessel-detail zoom: Standard Map below zoom 9 and Satellite Hybrid from zoom 9, aligned with the switch from overview vessels to type-coloured vessel symbols
- Full-screen map workspace with compact left and right toolbars
- Independent floating business panels with drag, minimize, hide, close, multi-window, and viewport-boundary support
- Unified medium-large blue-and-white business dialogs for modules 01–03, 05–09, and the live statistics summary, with enlarged readable typography
- Satellite data-readiness panel for reference imagery, pollution footprints, SAR/optical product access, and observation-target status
- Pre-event AIS passage screening by event time, lookback window and distance, with dark-red identified passage segments
- Alert and response center with warning totals, priority levels, map location, and external-channel configuration status
- Evidence and report workspace with record-completeness checks, event location, and downloadable review-draft summaries

Modules 10–13 use the records currently returned by the local API. Functions that require dedicated satellite products, external message gateways, or an analyst approval workflow are shown as pending until those services are configured.

### 11号窗口：事前航段筛选

- 默认查询事件前24小时，可选择6小时至7天；所有时间显示为UTC。
- 仅连接窗口内、严格早于事件时间的相邻AIS点，超过30分钟的断档不连接。
- 经过时间由相邻点线性估算。候选船舶不等于已经确认的污染来源。
- “SHOW PASSAGE”突出显示产生匹配的两个AIS点之间的航段，标出船名、MMSI和历史时间；不把它混同于船舶当前的位置。09号窗口仍用于查询较长的历史轨迹。
- 自动刷新不会将这段事前证据替换成事后轨迹。没有事前记录时显示无候选，不补造轨迹或修改数据库中的可疑船舶名单。

## 新增：油污事件自动预警

已接入现有事件刷新，新增高/中风险自动弹窗、低风险通知、未处理数量、油污及预测范围高亮、候选船轨迹/回放、确认与HTML参考报告。正常入口保持不变；开发测试请打开 `http://127.0.0.1:5173/?devAlerts=1`，在03 System Status底部点击“模拟油污预警”。测试记录与正常模式隔离，不写数据库。

直接双击原来的 `start_platform.bat` 就会启动平台并自动弹出一条测试预警，无需改网址。正常业务页面仍可通过不带参数的地址访问。

文件说明、真实API/WebSocket接入和后端待配合事项见 [油污自动预警说明](alerts/README.md)。确认当前仅在本机浏览器保存；正式事件没有提供的预测、概率和异常字段显示待接入/未评估。

## Main files

- `index.html` — dashboard structure, panels, controls, and labels
- `styles.css` — responsive business-screen layout, colors, and visual styling
- `app.js` — map rendering, API calls, statistics, filtering, and interaction
- `floating-panels.js` — reusable floating-panel state, drag, focus, window controls, and boundary management

To run the complete local platform, double-click `..\start_platform.bat` and open `http://127.0.0.1:5173/`.
