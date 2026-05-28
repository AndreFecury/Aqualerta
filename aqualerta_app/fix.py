
f = open("android/gradle/wrapper/gradle-wrapper.properties", "r", encoding="utf-8")
c = f.read()
f.close()
c = c.replace("gradle-8.9-bin.zip", "gradle-8.11.1-bin.zip")
f = open("android/gradle/wrapper/gradle-wrapper.properties", "w", encoding="utf-8")
f.write(c)
f.close()
print("Feito!")

