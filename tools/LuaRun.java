import java.io.FileReader;
import java.io.Reader;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaClosure;

/**
 * Runs Lua files, in order, in one Kahlua environment (the game's VM and stdlib; run it with the game folder
 * as the working directory so stdlib.lua is found). Used for the offline tests of the add-on with a mocked
 * game API: test/offline/*.lua.
 */
public final class LuaRun {
    public static void main(String[] args) throws Exception {
        J2SEPlatform platform = new J2SEPlatform();
        KahluaTable env = platform.newEnvironment();
        KahluaThread thread = new KahluaThread(System.out, platform, env);
        thread.debugOwnerThread = Thread.currentThread();
        for (String path : args) {
            LuaClosure closure;
            try (Reader r = new FileReader(path, java.nio.charset.StandardCharsets.UTF_8)) {
                closure = LuaCompiler.loadis(r, path, env);
            }
            Object[] res = thread.pcall(closure, new Object[0]);
            if (res.length == 0 || res[0] != Boolean.TRUE) {
                System.out.println("ERROR in " + path + ":");
                for (int i = 1; i < res.length; i++) System.out.println("  " + res[i]);
                System.exit(1);
            }
        }
    }
}
