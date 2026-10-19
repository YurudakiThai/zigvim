# TUI Editor Implementation Plan

## สถานะ: ✅ เสร็จสมบูรณ์ (Complete)

เอกสารนี้อธิบายการแก้ไขปัญหาที่ทำให้ zigvim ไม่สามารถพิมพ์และใช้คำสั่งบน macOS M2 ได้

## ปัญหาที่พบ (Root Causes)

1. **Render Bug**: Status bar และ message bar ถูกวาดทับ editor content
2. **Buffer Corruption**: ใช้ buffer เดียวกันสำหรับ formatting หลาย string
3. **Command Mode UX**: ไม่แสดง command buffer เมื่ออยู่ใน command mode
4. **Terminal Setup**: IXOFF flag ไม่ได้ถูก disable

## การแก้ไข (Solutions Implemented)

### TASK-TUI-001: Fix Terminal Raw Mode ✅
- เพิ่ม `IXOFF = false` ใน termios settings
- ปรับปรุง escape sequence handling

### TASK-TUI-002: Robust Key Parsing ✅
- แก้ไข readKey ให้จัดการกับ incomplete escape sequences
- เพิ่ม unread_byte buffer สำหรับ push back

### TASK-TUI-003: Fix Argument Parsing ✅
- แก้ไข main.zig ให้รับ filename argument ได้ถูกต้อง
- แยกแยะระหว่าง Lua script mode และ editor mode

### TASK-TUI-004: Buffer/Cursor Management ✅
- Implement editor.zig พร้อม:
  - Buffer management (ArrayList of lines)
  - Cursor movement (h,j,k,l + arrows)
  - Text insertion/deletion
  - Scrolling

### TASK-TUI-005: Rendering ✅
- Implement render.zig พร้อม:
  - Editor area (screen_rows - 2 lines)
  - Status bar (mode, filename, line count)
  - Message bar (status messages, command input)
  - Welcome message

### TASK-TUI-006: Mode Management ✅
- 3 Modes: Normal, Insert, Command
- Mode transitions:
  - Normal → Insert: `i`, `a`
  - Insert → Normal: `Esc`
  - Normal → Command: `:`
  - Command → Normal: `Esc`, `Enter`

### TASK-TUI-007: Commands ✅
- `:w` - บันทึกไฟล์
- `:q` - ออก (ตรวจสอบ dirty flag)
- `:wq`, `:x` - บันทึกแล้วออก
- `:q!` - ออกโดยไม่บันทึก

### TASK-TUI-008: Status Line ✅
- แสดง mode ปัจจุบัน
- แสดงชื่อไฟล์และสถานะ modified
- แสดงตำแหน่ง cursor
- แสดง status messages

### TASK-TUI-009: Manual Testing ✅
- ทดสอบบน macOS M2
- ทดสอบสร้างไฟล์ใหม่
- ทดสอบแก้ไขและบันทึก
- ทดสอบคำสั่งต่างๆ

## โครงสร้างไฟล์ (File Structure)

```
src/
├── main.zig       - Entry point, mode routing, event loop
├── terminal.zig   - Terminal I/O, raw mode, key reading
├── editor.zig     - Buffer management, cursor, text editing
└── render.zig     - Screen rendering, status bar, message bar
```

## Technical Details

### Terminal Raw Mode
```zig
// Disable all input processing
raw.iflag.IGNBRK = false;
raw.iflag.BRKINT = false;
raw.iflag.PARMRK = false;
raw.iflag.ISTRIP = false;
raw.iflag.INLCR = false;
raw.iflag.IGNCR = false;
raw.iflag.ICRNL = false;
raw.iflag.IXON = false;
raw.iflag.IXOFF = false;  // Added for macOS

// Disable output processing
raw.oflag.OPOST = false;

// Disable echo and canonical mode
raw.lflag.ECHO = false;
raw.lflag.ICANON = false;
raw.lflag.ISIG = false;
raw.lflag.IEXTEN = false;

// VMIN=0, VTIME=1 (100ms timeout)
raw.cc[VMIN] = 0;
raw.cc[VTIME] = 1;
```

### Screen Layout
```
┌────────────────────────────────────────┐
│ Editor Line 1                          │
│ Editor Line 2                          │
│ ...                                    │
│ Editor Line (screen_rows-2)            │
├────────────────────────────────────────┤
│ INSERT file.txt [+] - 10 lines  5:10  │ <- Status bar
├────────────────────────────────────────┤
│ Saved to file.txt (123 bytes)          │ <- Message bar
└────────────────────────────────────────┘
```

### Command Flow
```
Normal Mode
  ↓ ':'
Command Mode
  ↓ Type command (e.g., "wq")
  ↓ Enter
Execute Command
  ↓ Save/Quit/etc.
Normal Mode (or Exit)
```

## ผลทดสอบ (Test Results)

| Feature | Status | Notes |
|---------|--------|-------|
| เปิดไฟล์ | ✅ Pass | เปิดไฟล์ที่มีอยู่ได้ |
| สร้างไฟล์ใหม่ | ✅ Pass | สร้างไฟล์ใหม่เมื่อยังไม่มี |
| พิมพ์ตัวอักษร | ✅ Pass | แสดงผลถูกต้อง |
| Insert Mode | ✅ Pass | เข้า/ออกได้ปกติ |
| Normal Mode | ✅ Pass | h,j,k,l,x,d ทำงาน |
| Command Mode | ✅ Pass | แสดง :command ใน message bar |
| :w | ✅ Pass | บันทึกไฟล์ |
| :q | ✅ Pass | ออก (ตรวจสอบ dirty) |
| :wq | ✅ Pass | บันทึกแล้วออก |
| :q! | ✅ Pass | ออกโดยไม่บันทึก |
| Arrow Keys | ✅ Pass | เลื่อน cursor |
| Ctrl+Q | ✅ Pass | ออกทันที |
| Ctrl+S | ✅ Pass | บันทึก |
| macOS M2 | ✅ Pass | ไม่มีปัญหา input |

## บทเรียนที่ได้ (Lessons Learned)

1. **Terminal Layout**: ต้องคำนวณ screen layout ให้ถูกต้อง ไม่งั้น UI elements จะทับกัน
2. **Buffer Management**: ใช้ buffer แยกสำหรับแต่ละ string เพื่อป้องกัน corruption
3. **User Feedback**: ใน command mode ต้องแสดง command ที่กำลังพิมพ์ให้ผู้ใช้เห็น
4. **Platform-Specific**: macOS อาจมี termios flags ที่ต่างจาก Linux

## ขั้นตอนถัดไป (Next Steps)

ถ้าต้องการพัฒนาต่อ:
1. เพิ่ม Undo/Redo system
2. เพิ่ม Syntax highlighting
3. เพิ่ม Search/Replace
4. เพิ่ม Multiple buffers/tabs
5. เพิ่ม Vim motions เพิ่มเติม
6. เพิ่ม Configuration file support

## อ้างอิง (References)

- [Kilo Editor Tutorial](https://viewsourcecode.com/snaptoken/kilo/)
- [Zig std.ArrayList Documentation](https://ziglang.org/documentation/master/std/array_list.html)
- [termios(3) Manual](https://man7.org/linux/man-pages/man3/termios.3.html)
