from facts import UnknownType

class KVStore:
    # every value is either of the specified type or UnknownType
    def __init__(self):
        self.state = {}
        self.var_states = {}
        self.state_log = []

    def add_var(self, var, init_value, init_type):
        self.state[var] = init_value
        self.var_states[var] = {"type":init_type}

    def log(self, key, kind, value, old_value):
        self.state_log.append((key, kind, value, old_value))

    def event(self, kind, state, value, dtype):
        # record current state and old state
        assert (type(value) is dtype or value is UnknownType) and state in self.state and self.var_states[state]["type"] is dtype
        self.log(state, kind, value, self.state[state])
        self.state[state] = value

    # datatype manipulation
    def set_b(self, flag):
        self.event("set", flag, True, bool)

    def clear_b(self, flag):
        self.event("clear", flag, False, bool)

    def toggle_b(self, flag):
        self.event("toggle", flag, not self.state[flag], bool)

    def inc_i(self, var):
        self.event("inc", var, self.state[var]+1, int)
    
    def dec_i(self, var):
        self.event("dec", var, self.state[var]-1, int)

    def add_i(self, var, value):
        self.event("add", var, self.state[var]+value, int)

    def clear_i(self, var):
        self.event("clear", var, 0, int)
    
    def append_s(self, var, value):
        self.event("append", var, self.state[var]+value, str)

    def clear_s(self, var):
        self.event("clear", var, "", str)

    def add_set(self, var, value):
        self.event("add", var, self.state[var] | set([value]), set)

    def remove_set(self, var, value):
        self.event("remove", var, self.state[var] - set([value]), set)

    def clear_set(self, var):
        self.event("clear", var, set(), set)

    def add_list(self, var, value):
        self.event("add", var, self.state[var] + [value], list)
    
    def remove_list(self, var, value):
        self.event("remove", var, [x for x in self.state[var] if x!=value], list)

    def tail_pop_list(self, var):
        self.event("pop", var, self.state[var][:-1], list)
    
    def head_pop_list(self, var):
        self.event("head_pop", var, self.state[var][1:], list)

    def clear_list(self, var):
        self.event("clear", var, [], list)

    def print_log(self):
        for key, kind, value, old_value in self.state_log:
            print(f"{kind:10s}\t[{self.var_states[key]['type'].__name__:4s}]\t{key:15s}\t\t{str(value):20s}\t{str(old_value):20s}")

    def print_state(self):
        for key, value in self.state.items():
            print(f"{key}\t{value}")

    def gen_facts(self, fact):
        # return the fact surface for this state
        for k, v in self.state.items():
            if v is UnknownType:
                fact(k, "unknown")
            if type(v) is bool:
                fact(k, v)
            if type(v) is int:
                fact(k, v)
            if type(v) is str:
                fact(k, v)
            if type(v) is set:
                for x in v:
                    fact(k, x)
            if type(v) is list:
                for x in v:
                    fact(k, x)

if __name__=="__main__":
    kv = KVStore()
    kv.add_var("x", 0, int)
    kv.add_var("y", 0, int)
    kv.add_var("z", 0, int)
    kv.add_var("flag", False, bool)
    kv.add_var("name", "", str)
    kv.add_var("set", set(), set)
    kv.add_var("list", [], list)

    kv.inc_i("x")
    kv.inc_i("x")
    kv.inc_i("x")
    kv.inc_i("x")
    kv.inc_i("y")
    kv.inc_i("y")
    kv.inc_i("y")
    kv.inc_i("y")
    kv.inc_i("z")
    kv.inc_i("z")
    kv.inc_i("z")
    kv.inc_i("z")
    kv.set_b("flag")
    kv.toggle_b("flag")
    kv.append_s("name", "hello")
    kv.append_s("name", "world")
    kv.add_set("set", "blue")
    kv.add_set("set", "earth")
    kv.add_list("list", "walk")
    kv.add_list("list", "run")
    kv.print_state()
    kv.print_log()
    kv.gen_facts(print)
    kv.clear_i("x")
    kv.clear_i("y")
    kv.clear_i("z")
    kv.clear_b("flag")
    kv.clear_s("name")
    kv.clear_set("set")
    kv.clear_list("list")
    kv.print_state()
    kv.print_log()
    kv.gen_facts(print)
    kv.inc_i("x")
    kv.inc_i("x")
    kv.inc_i("x")
    kv.inc_i("x")
    kv.inc_i("y")
    kv.inc_i("y")
    kv.inc_i("y")
    kv.inc_i("y")
    kv.inc_i("z")
    kv.inc_i("z")
    kv.inc_i("z")
    kv.inc_i("z")
    kv.set_b("flag")
    kv.toggle_b("flag")
    kv.append_s("name", "hello")
    kv.append_s("name", "world")
    kv.add_set("set", 2)
    kv.add_set("set", 5)
    kv.add_list("list", 2)
    kv.add_list("list", 5)
    kv.print_state()
    kv.print_log()
    kv.gen_facts(print)
    kv.clear_i("x")
    kv.clear_i("y")
    kv.clear_i("z")
    kv.clear_b("flag")
    kv.clear_s("name")
    kv.clear_set("set")
    kv.gen_facts(print)