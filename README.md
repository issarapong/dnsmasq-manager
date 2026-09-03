# dns-dev-dnsmasq-manager

จัดการ local dev DNS บน macOS — dnsmasq + `/etc/resolver` ในที่เดียว

ปัญหาที่แก้: การเพิ่มโดเมน dev ต้องแตะสองที่เสมอ — zone file ของ dnsmasq กับ
`/etc/resolver/<tld>` ของ macOS ถ้าลืมอย่างหลัง dnsmasq จะตอบถูกทุกอย่างแต่ระบบ
ไม่เคยส่ง query มาให้เลย และ `dig` ธรรมดาก็ไม่ฟ้อง เพราะมันข้าม resolver ของระบบ

## สามหน้าเหมือนกัน เลือกใช้ตามสะดวก

| | ที่อยู่ | รัน |
|---|---|---|
| menu bar app | `app/App.swift` | `app/build.sh` → `~/Applications/dnsdev.app` |
| CLI | `cli/dnsdev` | `dnsdev add myapp.test` |
| web UI | `web/dnsdev-ui` | `dnsdev-ui` แล้วเปิด browser ให้เอง |

`~/.local/bin/dnsdev` และ `~/.local/bin/dnsdev-ui` เป็น symlink มาที่รีโปนี้
แก้ไฟล์ที่นี่มีผลทันที — แต่ถ้า `/Volumes/Server` ไม่ได้ mount คำสั่งจะหาย

## build แอป

```
app/build.sh          # universal binary + bundle + ad-hoc sign + ติดตั้ง
```

ตรวจว่าแอปเห็นระบบตรงกับความจริงไหม โดยไม่ต้องเปิด popover:

```
~/Applications/dnsdev.app/Contents/MacOS/dnsdev --doctor
```

## สิ่งที่ควรรู้ก่อนแก้ต่อ

- **สิทธิ์ root** — แอปรันด้วยสิทธิ์ผู้ใช้ปกติ งานที่ต้อง root (`/etc/resolver`,
  `launchctl`) รวบเป็นสคริปต์เดียวแล้วขอผ่าน `osascript ... with administrator
  privileges` กรอกรหัสครั้งเดียวต่อหนึ่ง action — อย่าแตกเป็นหลายคำสั่ง
- **ScrollView ใน popover** — `MenuBarExtra` ย่อหน้าต่างตามเนื้อหา ส่วน `ScrollView`
  ไม่มีความสูงในตัว ให้แค่ `.frame(maxHeight:)` แล้วมันจะยุบเหลือ 0 ต้องวัดเนื้อใน
  ด้วย `GeometryReader` + `PreferenceKey` แล้วกำหนดความสูงตรง ๆ (ดู `ListHeightKey`)
- **ดีบัก popover** — เปิดจากสคริปต์ได้โดยไม่ต้องขอ assistive access ด้วยการหา
  `NSStatusBarButton` ใน `NSApp.windows` แล้วเรียก `performClick(nil)` จากนั้น dump
  `NSApp.windows` ดูขนาดหน้าต่างจริง
- **TLD** — `.test` สงวนตาม RFC 6761 ใช้ตัวนี้ `.local` ใช้ไม่ได้เด็ดขาด (macOS ส่งไป
  mDNSResponder เสมอ) `.dev` อยู่ใน HSTS preload ต้องมี cert

## ค้างอยู่

- `cli/dnsdev` ยัง grep แค่ `^address=/` — มองไม่เห็น zone ชนิด `server=` ที่เพิ่มจากแอป
  (`dnsdev ls` / `dnsdev doctor` จะไม่แสดง) `web/dnsdev-ui` ยังไม่ได้ตรวจเรื่องนี้

## attic/

- `App.swift.v1.0` — เวอร์ชันก่อนเพิ่ม server=, แก้ไข zone, ปุ่มแก้ปัญหา, login item
- `masq-prototype/` — แอปอีกตัวที่เขียนซ้ำโดยไม่รู้ว่ามีของเดิมอยู่แล้ว เก็บไว้เผื่อ
  ยกบางส่วนมาใช้ (raw config editor, ตรวจ bind UDP/53, ช่องทดสอบชื่อโฮสต์อิสระ)
