中心呼吸完成動畫
實作規格文件
此文件描述「所有任務完成」Empty State 中，中心呼吸圖示錶面動畫的完整實作規格，供 Claude Code 還原至 Garmin Connect IQ 或等效原生平台。

01 · Overview
動畫概述
使用者開啟任務清單 APP，發現今日所有任務已完成，錶面播放一次性入場動畫，接著進入持續呼吸的 Idle 狀態。整體時長約 3 秒完成入場，之後無限循環呼吸效果。

畫布尺寸
300 × 300 px（邏輯座標）
錶面圓心
cx=150, cy=150, r=150
底色
#060608（接近純黑）
入場總時長
~3.0 秒（後接無限 Idle）
更新頻率
60fps（requestAnimationFrame）
字體
Barlow / Barlow Condensed
02 · Timeline
完整動畫時序表
所有時間以秒為單位，t=0 為動畫啟動時刻。

時間區間	元素	動作	Easing
0.0 → 0.0	Watch Bezel	外框環靜態繪製（無動畫，始終可見）	—
0.3 → 0.9	Orbit Ring	虛線軌道環淡入，alpha 0 → 0.25	easeOutCubic
1.4 → 2.1	Inner Circle	中心圓從 scale(0) → scale(1) 彈性縮放入場	easeOutBack
1.4 → 2.0	Inner Ring	中心圓外框同步淡入	easeOutCubic
1.6 → 2.3	Halos ×3	三層光暈整體淡入（各自呼吸相位不同）	easeOutCubic
1.9 → 2.5	Checkmark	勾選符號分兩段描繪（左臂 → 右臂）	easeOutCubic
2.4 → 3.1	Text	「所有任務完成」淡入；副文字同步淡入	easeOutCubic
3.1 → ∞	Idle	三層光暈持續呼吸，sin 波形交錯	Math.sin(t × 0.9 + phase)
03 · Easing Functions
緩動函式定義
所有緩動以 t ∈ [0,1] 為輸入，回傳 eased t。

// 通用 progress 計算（將全域時間 t 映射到 [0,1]）
function progress(t, start, end) {
  return Math.max(0, Math.min(1, (t - start) / (end - start)));
}

const ease = {
  // 使用於：光暈淡入、文字淡入、外框環
  outCubic:  t => 1 - Math.pow(1 - t, 3),

  // 使用於：中心圓入場（帶彈性過衝）
  outBack: t => {
    const c1 = 1.70158, c3 = c1 + 1;
    return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
  },
};
04 · Layer by Layer
逐層繪製說明
LAYER 01
Watch Bezel 外框環
t=0，靜態
每幀都重新繪製，不受動畫進度影響。作用為確保錶面形狀可見。

// 外框環（深灰，3px）
ctx.beginPath();
ctx.arc(150, 150, 148, 0, Math.PI * 2);
ctx.strokeStyle = '#1a1a1e';
ctx.lineWidth = 3;
ctx.stroke();

// 內層細環（更深，1px）
ctx.beginPath();
ctx.arc(150, 150, 143, 0, Math.PI * 2);
ctx.strokeStyle = '#111114';
ctx.lineWidth = 1;
ctx.stroke();
LAYER 02
Orbit Ring 虛線軌道環
0.3s → 0.9s
半徑 132px 的虛線圓環，暗示錶面尺度邊界，輕度裝飾性元素。

const ringAlpha = ease.outCubic(progress(t, 0.3, 0.9));
ctx.globalAlpha = ringAlpha * 0.25;
ctx.beginPath();
ctx.arc(150, 150, 132, 0, Math.PI * 2);
ctx.strokeStyle = '#3a6a3a';
ctx.lineWidth = 1;
ctx.setLineDash([3, 10]);  // 間距: 3px 實線, 10px 空白
ctx.stroke();
ctx.setLineDash([]);
LAYER 03
Breathing Halos 呼吸光暈 ×3
1.6s → ∞
三層同心放射漸層，以不同相位 sin 波交錯呼吸，製造有機律動感。

呼吸週期：每層光暈呼吸頻率相同（0.9 rad/s），但相位偏移 120°（π×0.66），使三層交錯不同步，避免整齊閃爍的機械感。
const breathIn = ease.outCubic(progress(t, 1.6, 2.3));

const halos = [
  { radius: 122, phase: 0,              baseAlpha: 0.10 },
  { radius: 100, phase: Math.PI * 0.66, baseAlpha: 0.16 },
  { radius: 78,  phase: Math.PI * 1.33, baseAlpha: 0.22 },
];

halos.forEach(({ radius, phase, baseAlpha }) => {
  const pulse = 0.5 + 0.5 * Math.sin(t * 0.9 + phase);
  const grad = ctx.createRadialGradient(150,150,0, 150,150, radius);
  grad.addColorStop(0,   `rgba(60,140,60,${baseAlpha * (0.6 + 0.4*pulse)})`);
  grad.addColorStop(0.5, `rgba(60,120,60,${baseAlpha * 0.4})`);
  grad.addColorStop(1,   'rgba(60,120,60,0)');

  ctx.globalAlpha = breathIn * (0.8 + 0.2 * pulse);
  ctx.beginPath();
  ctx.arc(150, 150, radius, 0, Math.PI * 2);
  ctx.fillStyle = grad;
  ctx.fill();
});
LAYER 04
Inner Circle 中心圓
1.4s → 2.1s
從中心 scale(0) 彈性放大至 scale(1)，使用 easeOutBack 製造微彈跳感。

const circleScale = ease.outBack(progress(t, 1.4, 2.1));

// 儲存狀態 → 平移至圓心 → 縮放 → 還原
ctx.save();
ctx.translate(150, 150);
ctx.scale(circleScale, circleScale);
ctx.translate(-150, -150);

// 外框環
ctx.beginPath();
ctx.arc(150, 150, 62, 0, Math.PI * 2);
ctx.strokeStyle = '#2a4a2a';
ctx.lineWidth = 1.5;
ctx.globalAlpha = ease.outCubic(progress(t, 1.4, 2.0));
ctx.stroke();

// 填色（放射漸層，中心較亮）
const innerGrad = ctx.createRadialGradient(150,150,0, 150,150, 62);
innerGrad.addColorStop(0, '#0f1f0f');
innerGrad.addColorStop(1, '#0a150a');
ctx.beginPath();
ctx.arc(150, 150, 62, 0, Math.PI * 2);
ctx.fillStyle = innerGrad;
ctx.fill();
ctx.restore();
LAYER 05
Checkmark 勾選符號
1.9s → 2.5s
分兩段依序描繪，模擬手寫筆觸。前半段畫左臂，後半段畫右臂，帶發光陰影。

// 三個控制點
const p1 = [126, 152];  // 起點（左下）
const p2 = [144, 170];  // 轉折點（中央低點）
const p3 = [178, 132];  // 終點（右上）

const checkPct = ease.outCubic(progress(t, 1.9, 2.5));

ctx.strokeStyle = '#78cc78';
ctx.lineWidth = 3.5;
ctx.lineCap = 'round';
ctx.lineJoin = 'round';
ctx.shadowColor = 'rgba(120,200,120,0.6)';
ctx.shadowBlur = 12;

if (checkPct < 0.5) {
  // 前半：p1 → p2
  const seg = checkPct / 0.5;
  ctx.beginPath();
  ctx.moveTo(p1[0], p1[1]);
  ctx.lineTo(lerp(p1[0], p2[0], seg), lerp(p1[1], p2[1], seg));
  ctx.stroke();
} else {
  // 後半：p1 → p2 → p3
  const seg = (checkPct - 0.5) / 0.5;
  ctx.beginPath();
  ctx.moveTo(p1[0], p1[1]);
  ctx.lineTo(p2[0], p2[1]);
  ctx.lineTo(lerp(p2[0], p3[0], seg), lerp(p2[1], p3[1], seg));
  ctx.stroke();
}
ctx.shadowBlur = 0; // 重置，避免影響後續元素
LAYER 06
Text 文字層
2.4s → 3.1s
主文字「所有任務完成」與副文字「休息一下」同步淡入。位置固定，無位移動畫。

const textAlpha = ease.outCubic(progress(t, 2.4, 3.1));

// 頂部小標（輔助性，半透明）
ctx.globalAlpha = textAlpha * 0.5;
ctx.font = "400 8px 'Barlow Condensed', sans-serif";
ctx.fillStyle = '#3a5a3a';
ctx.textAlign = 'center';
ctx.letterSpacing = '4px';
ctx.fillText('TASKS', 150, 72);

// 主文字
ctx.globalAlpha = textAlpha;
ctx.font = "300 16px 'Barlow', sans-serif";
ctx.fillStyle = '#8abf8a';
ctx.fillText('所有任務完成', 150, 228);

// 副文字
ctx.globalAlpha = textAlpha * 0.5;
ctx.font = "300 9px 'Barlow Condensed', sans-serif";
ctx.fillStyle = '#3a4a3a';
ctx.letterSpacing = '2px';
ctx.fillText('休息一下', 150, 246);
05 · Colors
色彩規格
#060608 背景
#1a1a1e 外框環
#3a6a3a 虛線軌道
#2a4a2a 中心圓框
#78cc78 勾選線條
#8abf8a 主文字
#3a5a3a 副文字
rgba(60,140,60) 光暈基色
06 · Idle State
Idle 呼吸狀態（入場後持續）
入場動畫結束後，三層光暈維持以下規律永久循環：

// 每幀計算（t 持續增加）
halos.forEach(({ radius, phase, baseAlpha }) => {
  // pulse 在 0~1 之間以 sin 波震盪
  // 頻率: 0.9 rad/s ≈ 每 6.98 秒一個完整週期
  const pulse = 0.5 + 0.5 * Math.sin(t * 0.9 + phase);

  // Alpha 範圍: baseAlpha×0.6 ~ baseAlpha×1.0
  // globalAlpha 範圍: 0.8 ~ 1.0
});
注意：三層光暈的相位差為 π×0.66（≈ 120°），模擬三角形對稱相位，確保任何時刻都有光暈在不同亮度階段，整體看起來持續呼吸而非同步閃爍。
07 · Implementation Notes
實作注意事項
Canvas 裁切
每幀開始須先以 ctx.arc(150,150,150) + ctx.clip() 裁切為圓形，再進行所有繪製，確保內容不超出錶面邊界。每幀 clearRect 前須 ctx.restore() 取消 clip。

globalAlpha 管理
每次改變 globalAlpha 前必須 ctx.save()，繪製後 ctx.restore()。否則 alpha 值會疊加影響後續層次。

shadowBlur 效能
勾選符號使用 shadowBlur=12，繪製完成後立即設回 0，避免對後續文字層造成非預期模糊。

Connect IQ 移植
Connect IQ 使用 Monkey C，無 Canvas 2D API。建議：
· 光暈以 dc.setColor() + dc.fillCircle() 多層疊加模擬
· 入場動畫以 timer + 狀態機控制每一層的進度
· 勾選符號可用 dc.drawLine() 兩段分別繪製
· 呼吸效果以 WatchUi.requestUpdate() 每秒觸發若干次更新