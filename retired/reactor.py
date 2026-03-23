from facts import UnknownType
from kvstore import KVStore
    
class Reactor:
    def __init__(self, name, manager, parent=None):
        self.initial_state() 
        self.name = name 
        self.manager = manager
        self.sub_actors = {}
        self.store = KVStore()
        self.parent = parent 
    
    def get_path(self):
        if self.parent is None:
            return self.name
        return self.parent.get_path() + "." + self.name
    
    def enumerate_children(self):
        for actor in self.sub_actors.values():
            yield actor
            yield from actor.enumerate_children()

    def set_time(self, time):
        self.time = time

    def recv_message(self, actor, message, args):
        if message=="time":
            self.set_time(args[0])
        pass 

    def send_message(self, actor, message, args):
        self.manager.send_to(self.name, actor, message, args)

    def attach_actor(self, actor):
        self.sub_actors[actor.name] = actor
        actor.parent = self

    def initial_state(self):
        pass 


if __name__=="__main__":
    a = Reactor("a", None)    