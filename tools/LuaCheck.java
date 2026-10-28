import java.io.FileReader;
import java.io.Reader;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.KahluaTable;

/** Compiles Lua files with the game's own Kahlua compiler (syntax check only, nothing is run). */
public final class LuaCheck {
    public static void main(String[] args) throws Exception {
        J2SEPlatform platform = new J2SEPlatform();
        KahluaTable env = platform.newTable();
        int bad = 0;
        for (String path : args) {
            try (Reader r = new FileReader(path, java.nio.charset.StandardCharsets.UTF_8)) {
                LuaCompiler.loadis(r, path, env);
                System.out.println("ok   " + path);
            } catch (Throwable t) {
                bad++;
                System.out.println("FAIL " + path + ": " + t);
            }
        }
        System.exit(bad == 0 ? 0 : 1);
    }
}
