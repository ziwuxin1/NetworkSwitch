from PIL import Image, ImageDraw
from pathlib import Path
root = Path(r"outputs/NetworkSwitchCyber/source")
scale = 16
im = Image.new("RGBA", (48*scale,48*scale), (0,0,0,0))
d = ImageDraw.Draw(im)
def pts(p): return [(x*scale,y*scale) for x,y in p]
yellow, dark, pink = "#FCEE0A", "#0B0A10", "#FF2A6D"
d.polygon(pts([(0,0),(38,0),(48,10),(48,48),(10,48),(0,38)]), fill=yellow)
d.line(pts([(7,31),(19,31),(27,17),(41,17)]), fill=dark, width=4*scale, joint="curve")
d.line(pts([(19,31),(41,31)]), fill=dark, width=4*scale)
d.rectangle((37*scale,14*scale,43*scale-1,20*scale-1), fill=pink)
d.rectangle((37*scale,28*scale,43*scale-1,34*scale-1), fill=dark)
d.line(pts([(4,44),(12,44)]), fill=dark, width=2*scale)
im.resize((256,256),Image.Resampling.LANCZOS).save(root/"NetworkSwitch.ico", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
im.resize((256,256),Image.Resampling.LANCZOS).save(root/"NetworkSwitch-logo.png")
print("Generated 7-size icon")
