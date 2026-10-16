# 効果音（DJ ミックスの切り替えに重ねる音）

アプリに同梱する素材。曲の切り替え（PlaylistEngine のクロスフェード）に SFX 用プレイヤーで重ねる。
ファイル名は役割で付け直してある（`riser_*` 上げ / `down_*` 下げ / `impact_*` 一撃 / `brake_*` 回転停止）。
末尾の `_2s` などは長さ。ライザーは終わりを切り替え点に合わせて鳴らすので、長さは拍数に近いものを選ぶ。

## 出どころとライセンス

- `riser_*.wav`, `down_*.wav`, `brake_vinyl_*.wav` — Free Riser Producer Kit（GareBear99 / TizWildin Entertainment）
  https://github.com/GareBear99/Free-Riser-Producer-Kit
  README の条件: 商用・非商用とも無料、クレジット不要。素材単体のサンプルパックとしての再配布は不可（アプリへの同梱は可）。
  44.1kHz / 16bit / モノラル WAV。
- `impact*.mp3`, `sub_drop.mp3`, `crash.mp3`, `reverse_cymbal.mp3`, `spinback.mp3`（元: vinyl-rewind）, `tape_stop.mp3`, `downlifter.mp3`
  — MixClap「Free Transition Sound Effects」 https://www.mixclap.com/en/blog/transition-sound-effects
  CC0（作者が権利を放棄）。そのままの再販は不可。48kHz / 64kbps / ステレオ MP3（配布元が web 用に用意したもの。WAV 原本は無い）。
