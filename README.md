# dns-dev-dnsmasq-manager

จัดการ local dev DNS บน macOS — dnsmasq + `/etc/resolver` ในที่เดียว

ปัญหาที่แก้: การเพิ่มโดเมน dev ต้องแตะสองที่เสมอ — zone file ของ dnsmasq กับ
`/etc/resolver/<tld>` ของ macOS ถ้าลืมอย่างหลัง dnsmasq จะตอบถูกทุกอย่างแต่ระบบ
ไม่เคยส่ง query มาให้เลย และ `dig` ธรรมดาก็ไม่ฟ้อง เพราะมันข้าม resolver ของระบบ

## ดาวน์โหลด

[dnsdev 1.1](https://github.com/issarapong/dnsmasq-manager/releases/latest) — universal
(Intel + Apple Silicon), macOS 14+ เซ็นแบบ ad-hoc ไม่ได้ notarize ต้องปลด quarantine
หนึ่งครั้งหลังแตกไฟล์:

```
xattr -dr com.apple.quarantine ~/Applications/dnsdev.app
```

## สองชั้น

**ชั้น DNS** (dnsmasq + `/etc/resolver`) ตอบว่าโดเมนนี้คือเครื่องไหน — แต่ยังต้อง
พิมพ์ `:3000` อยู่ดี **ชั้น https** (`dnsdevd`) ฟัง `:443` แล้วส่งต่อตามชื่อ
พร้อมออก cert ให้เอง จึงเปิด `https://myapp.test` ได้ตรง ๆ

```
dnsdev add myapp.test 3000     # DNS + route → https://myapp.test
dnsdev proxy install           # ติดตั้ง dnsdevd เป็น LaunchAgent
dnsdev trust                   # เอา CA เข้า System keychain (ครั้งเดียว)
```

route มีสองโหมด — **terminate** (ค่าเริ่มต้น) dnsdevd ถือ cert ให้ กับ
**passthrough** (`--pass`) ที่อ่านแค่ SNI แล้วส่ง TLS ดิบต่อ ใช้กับ VM หรือ
คอนเทนเนอร์ที่มี cert ของตัวเองอยู่แล้ว เช่น nginx ใน Lima — ถ้า terminate
ทับ cert เดิมจะหายไปหมด

## สามหน้าเหมือนกัน เลือกใช้ตามสะดวก

| | ที่อยู่ | รัน |
|---|---|---|
| menu bar app | `app/App.swift` | `app/build.sh` → `~/Applications/dnsdev.app` |
| CLI | `cli/dnsdev` | `dnsdev add myapp.test 3000` |
| web UI | `web/dnsdev-ui` | `dnsdev-ui` แล้วเปิด browser ให้เอง |
| proxy | `proxy/Proxy.swift` | รันเป็น LaunchAgent ไม่มีหน้าจอ |

ทั้งสามหน้าจัดการ route กับติดตั้ง cert ได้ครบเท่ากัน — แอปอยู่ในเมนู `⋯`
เว็บอยู่ในการ์ด "ชั้น https" CLI ใช้ `dnsdev proxy` / `dnsdev trust`

config ทั้งหมดอยู่ที่ `~/.config/dnsdev/routes.json` แก้มือได้ daemon เฝ้าอยู่
มีผลทันทีไม่ต้อง restart แก้ได้สามทาง:

- เมนู `⋯ → แก้ JSON ในแอป` — ตัวแก้ในตัวแอป ตรวจให้ก่อนบันทึก (`⌘S`)
- เมนู `⋯ → เปิด routes.json ในตัวแก้ข้อความ` หรือ `dnsdev proxy edit`
- แก้ไฟล์ตรง ๆ ด้วยอะไรก็ได้

JSON พังจะไม่ล้ม route เดิม — daemon ใช้ค่าเดิมต่อจนกว่าจะแก้ถูก แล้ว log บอกไว้

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
- **cert ต้องมี SKI/AKI** — ไม่มีแล้ว Safari ผ่านสบายแต่ OpenSSL 3 (Node, Python,
  curl ที่ลิงก์กับมัน) ปฏิเสธด้วย `Missing Authority Key Identifier`
- **เพดาน 398 วันไม่บังคับกับ CA ของเราเอง** — กฎนั้นใช้กับ cert ที่สืบไปถึง root
  ที่ติดมากับ OS ส่วน root ที่ผู้ใช้ติดตั้งเองได้รับยกเว้น (mkcert ออกใบอายุ 822 วัน
  แล้ว macOS ก็ยอมรับ) `dnsdevd` ใช้ 397 วันเพราะไม่มีเหตุต้องยาวกว่านั้น —
  มันออกใบใหม่ทุกครั้งที่ route เปลี่ยนอยู่แล้ว
- **wildcard ของ TLS ครอบชั้นเดียว** — `*.myapp.test` ไม่ครอบ `a.b.myapp.test` และ
  `*.*.x` ใช้ไม่ได้ตามสเปค ขณะที่ DNS ฝั่ง dnsmasq ครอบทุกชั้น `dnsdevd` จึงออก cert
  ตาม SNI ที่เห็นจริงแล้ว cache ไว้ ไม่งั้นสัญญา "ทุกชั้น" จะพังที่ชั้น https
- **พอร์ตต่ำกว่า 1024** — macOS ไม่หวงเหมือน Linux ผูก `:443` ด้วยสิทธิ์ user ได้เลย
  `dnsdevd` จึงเป็น LaunchAgent ไม่ต้องเป็น root daemon งานที่ต้องขอรหัสเหลือแค่
  เอา CA เข้า System keychain
- **คิวของ listener** — `NWListener` รายงานสถานะกลับมาทางคิวที่ให้ไว้ ถ้า `reload()`
  รันบนคิวเดียวกันแล้วรอ semaphore มันจะรอตัวเองจนหมดเวลาแล้ว proxy ดับทั้งตัว
  (ดู `lq` ใน `Proxy.swift`)
- **Local Network privacy** — macOS กันไม่ให้ process ต่อไปยัง IP ในวงแลน จนกว่าจะ
  ได้รับอนุญาต และการถูกกันจะ **เงียบสนิท** ไม่ error ไม่ปิด connection แค่ค้าง
  loopback ได้รับยกเว้น ฉะนั้น route ที่ชี้ไป `127.0.0.1` ทำงานได้เสมอ แต่ route ที่ชี้ไป
  IP ของ VM จะค้างเมื่อ `dnsdevd` ถูกรันโดย launchd (รันจากเทอร์มินัลจะได้สิทธิ์ของ
  เทอร์มินัลติดมาด้วย จึงผ่าน — ทำให้หลงทางได้ง่ายมาก) เปิดสิทธิ์ให้ที่
  System Settings › Privacy & Security › Local Network · `dnsdevd` เลิกรอเองใน 5 วิ
  แล้ว log บอกสาเหตุไว้ ไม่ปล่อยค้างจน browser ยอมแพ้
- **ดีบักหน้าตาแอป** — `dnsdev --popover` เปิด popover ให้เองตอนขึ้น
- **TextEditor กับ JSON** — `TextEditor` ของ SwiftUI เปิด smart quotes ไว้ พิมพ์ `"`
  แล้วได้ `"` ซึ่งทำ JSON พังแบบมองด้วยตาแทบไม่เห็น ตัวแก้ในแอปจึงห่อ `NSTextView`
  เองแล้วปิดการแทนที่ทุกชนิด (ดู `CodeEditor`)

## ค้างอยู่

- `cli/dnsdev` ยัง grep แค่ `^address=/` — มองไม่เห็น zone ชนิด `server=` ที่เพิ่มจากแอป
  (`dnsdev ls` / `dnsdev doctor` จะไม่แสดง) `web/dnsdev-ui` ยังไม่ได้ตรวจเรื่องนี้

## attic/

- `App.swift.v1.0` — เวอร์ชันก่อนเพิ่ม server=, แก้ไข zone, ปุ่มแก้ปัญหา, login item
- `masq-prototype/` — แอปอีกตัวที่เขียนซ้ำโดยไม่รู้ว่ามีของเดิมอยู่แล้ว เก็บไว้เผื่อ
  ยกบางส่วนมาใช้ (raw config editor, ตรวจ bind UDP/53, ช่องทดสอบชื่อโฮสต์อิสระ)
