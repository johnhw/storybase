import copy 

class CONST:
    def __init__(self, x):
        self.x = x

    def __str__(self):
        return "<"+str(self.x)+">"
    
    def __repr__(self):
        return "<"+str(self.x)+">"


def descend(a, b):
    # recursively merge the dictionaries, overwriting the values of a with b
    # return a new dictionary (do not modify the input dictionaries)
    for key in b:
        if key in a:

            # warn if type changed
            if type(a[key]) != type(b[key]):
                print(f"Warning: type mismatch for key {key}: {type(a[key])} vs {type(b[key])}")

            if isinstance(a[key], dict) and isinstance(b[key], dict):
                a[key] = descend(a[key], b[key])
            else:
                a[key] = b[key]
        else:
            a[key] = b[key]
    return a


def print_entity(d, path="", indent=0):
    # nicely format the dictionary
    # use a path like format to show the hierarchy
    # /char/health: 10
    # and indent correctly
    for key in d:
        key_path = path +"/"+ str(key)
        if isinstance(d[key], dict) or isinstance(d[key], Entity):
            print(" "*indent+key_path)
            print_entity(d[key], "", indent+4)
        else:
            v = d[key]
            type_name = type(v).__name__
            if isinstance(v, CONST):
                v = v.x
                type_name += "["+type(v).__name__+"]"

            print(" "*indent+key_path + ": " + type_name + "(" + str(v) + ")")


# a History is attached to an entity
class History:
    def __init__(self):
        self.history = []
        self.index = []

    def sub_index(self):
        self.index.append(0)

    def sup_index(self):
        if len(self.index) == 0:
            raise ValueError("No index to pop")
        self.index.pop()

    def inc_index(self, level=-1):
        self.index[level] += 1    
        for i in range(level+1, len(self.index)):
            self.index[i] = 0

    def update(self, path, value):
        self.history.append(("update", self.index, path, value))

    def snapshot(self, entity):
        self.history.append(("snapshot", self.index, "/", copy.deepcopy(entity)))

    def undo(self, entity, steps=1):
        # work backwards until we find a snapshot for this entity
        # then apply the updates in order
        for i in range(len(self.history)-1, -1, -1):
            kind, index, name, value = self.history[i]
            if kind == "snapshot":
                # apply the updates
                for j in range(i+1, len(self.history)):
                    kind, index, path, value = self.history[j]
                    if kind == "update":
                        entity.set(path, value)
                break            
                            

class Entity:
    def __init__(self, name, d, history=None):
        self.name = name
        self.d = d
        self.history = history
        if self.history is not None:            
            self.history.snapshot(self)

    def __str__(self):
        return self.name + "(" + str(self.d)+")"
    
    def __getitem__(self, key):
        return self.d[key]
    
    def __setitem__(self, key, value):
        if key not in self.d:
            raise KeyError(f"Key {key} not found in {self.name}")        
        # check that the type matches
        if type(self.d[key]) != type(value):
            raise ValueError(f"Type mismatch for key {key}: {type(self.d[key])} vs {type(value)}")
        if isinstance(self.d[key], CONST):
            raise ValueError(f"Value for key {key} is a CONST")
        
        self.d[key] = value

    def __delitem__(self, key):
        raise ValueError("Cannot delete items from Entity")        

    def __iter__(self):
        return iter(self.d)
    
    def __len__(self):
        return len(self.d)
    
    def __contains__(self, key):
        return key in self.d
    
    def __repr__(self):
        return self.name + "(" + str(self.d) + ")"
    
    def pretty_print(self):
        print_entity(self.d)

    def set(self, path, value):        
        d = self 
        keys = path.split("/")[1:]
        for key in keys[:-1]:                                
            if key not in self.d:
                raise KeyError(f"Key <{key}> not found in entity <{self.name}>")
            if not isinstance(self.d[key], Entity):
                raise ValueError(f"Key <{key}> is not an entity <{self.name}>")            
            d = d[key]                
        d[keys[-1]] = value        
        if self.history is not None:
            self.history.update(path, value)

    def snapshot(self):
        if self.history is not None:
            self.history.snapshot(self)
            

history = History()

char = Entity("char", {
    "health": 10, 
    "alive": CONST(True),
    })

magic = Entity("magic", {"mana": 10, "recharge": 0})

player = Entity("player", {
    "char": char,
    "magic": magic,    
}, History())

#p = descend(char, player)

print(player)

player.set("/char/health", 20)
print(player)
player.set("/magic/mana", 20)
player.snapshot()

player.pretty_print()

