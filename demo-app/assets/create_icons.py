from PIL import Image

# Icon 1024x1024
img = Image.new('RGB', (1024, 1024), color=(28, 28, 30))
img.save('icon.png')

# Splash 1284x2778
splash = Image.new('RGB', (1284, 2778), color=(28, 28, 30))
splash.save('splash-icon.png')

print("Icons created!")
