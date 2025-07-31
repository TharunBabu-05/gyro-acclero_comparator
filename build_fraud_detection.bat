@echo off
echo Building Bus Fraud Detection APK...
echo.

cd /d c:\Users\tharu\gyro_compare_fixed

echo Cleaning previous build...
call flutter clean

echo Getting dependencies...
call flutter pub get

echo Building APK...
call flutter build apk --release

echo.
echo ✅ APK built successfully!
echo Location: build\app\outputs\flutter-apk\app-release.apk
echo.
echo 📱 Install on your bus device and test the fraud detection system!
pause
