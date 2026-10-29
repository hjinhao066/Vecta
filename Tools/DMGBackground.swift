import AppKit

// Build-time artwork only; matches the app's monochrome dark appearance.
let output=URL(fileURLWithPath:CommandLine.arguments[1])
let image=NSImage(size:NSSize(width:640,height:400))
image.lockFocus()
NSColor(srgbRed:9/255,green:10/255,blue:11/255,alpha:1).setFill()
NSRect(x:0,y:0,width:640,height:400).fill()
func label(_ text:String,_ size:CGFloat,_ y:CGFloat,_ color:NSColor) {
    let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color]
    let string=NSAttributedString(string:text,attributes:attributes)
    string.draw(at:NSPoint(x:(640-string.size().width)/2,y:y))
}
label("Vecta",32,326,.white)
label("Local. On your Mac.",14,298,NSColor(white:0.65,alpha:1))
label("→",36,188,NSColor(white:0.6,alpha:1))
label("Drag Vecta to Applications",14,60,NSColor(white:0.85,alpha:1))
image.unlockFocus()
guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {exit(1)}
try png.write(to:output)
