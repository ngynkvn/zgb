// Direct C bindings for raylib
pub const raylib = @cImport({
    @cInclude("raylib.h");
});

// Re-export commonly used types and functions
pub const Color = raylib.Color;
pub const Image = raylib.Image;
pub const Texture2D = raylib.Texture2D;
pub const Rectangle = raylib.Rectangle;
pub const KeyboardKey = raylib.KeyboardKey;

// Color constants
pub const WHITE = raylib.WHITE;
pub const BLACK = raylib.BLACK;
pub const DARKGRAY = raylib.DARKGRAY;
pub const LIGHTGRAY = raylib.LIGHTGRAY;
pub const GRAY = raylib.GRAY;
pub const GREEN = raylib.GREEN;
pub const RED = raylib.RED;

// Window functions
pub const initWindow = raylib.InitWindow;
pub const closeWindow = raylib.CloseWindow;
pub const windowShouldClose = raylib.WindowShouldClose;
pub const setTargetFPS = raylib.SetTargetFPS;
pub const getFrameTime = raylib.GetFrameTime;

// Drawing functions
pub const beginDrawing = raylib.BeginDrawing;
pub const endDrawing = raylib.EndDrawing;
pub const clearBackground = raylib.ClearBackground;
pub const drawTexture = raylib.DrawTexture;
pub const drawTextureEx = raylib.DrawTextureEx;
pub const drawTexturePro = raylib.DrawTexturePro;
pub const drawText = raylib.DrawText;
pub const drawFPS = raylib.DrawFPS;

// Texture functions
pub const loadTextureFromImage = raylib.LoadTextureFromImage;
pub const unloadTexture = raylib.UnloadTexture;
pub const updateTexture = raylib.UpdateTexture;

// Image functions
pub const genImageColor = raylib.GenImageColor;
pub const unloadImage = raylib.UnloadImage;
pub const imageFormat = raylib.ImageFormat;

// Input functions
pub const isKeyDown = raylib.IsKeyDown;
pub const isKeyPressed = raylib.IsKeyPressed;
pub const isKeyReleased = raylib.IsKeyReleased;

// Key codes
pub const KEY_RIGHT = raylib.KEY_RIGHT;
pub const KEY_LEFT = raylib.KEY_LEFT;
pub const KEY_UP = raylib.KEY_UP;
pub const KEY_DOWN = raylib.KEY_DOWN;
pub const KEY_Z = raylib.KEY_Z;
pub const KEY_X = raylib.KEY_X;
pub const KEY_ENTER = raylib.KEY_ENTER;
pub const KEY_BACKSPACE = raylib.KEY_BACKSPACE;
pub const KEY_ESCAPE = raylib.KEY_ESCAPE;
pub const KEY_SPACE = raylib.KEY_SPACE;
pub const KEY_P = raylib.KEY_P;
pub const KEY_R = raylib.KEY_R;

// Pixel format
pub const PIXELFORMAT_UNCOMPRESSED_R8G8B8A8 = raylib.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;

// Vector2
pub const Vector2 = raylib.Vector2;
