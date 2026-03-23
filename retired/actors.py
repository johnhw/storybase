import random

VERBOSE = False

def query_timelog(log, start_time, end_time, predicate):
    # a timelog is a sequence of (time, ...) tuples
    # return all tuples where predicate(...) is True
    # and start_time <= time <= end_time
    return [
        (t, *data)
        for t, *data in log
        if start_time <= t <= end_time and predicate(data)
    ]


def query_timelog_around(log, time, predicate):
    # return the closest events before and after the given time
    # where predicate(...) is True
    before, after = None, None
    for t, *data in reversed(log):
        if t < time and predicate(data):
            before = (t, *data)
            break
    for t, *data in log:
        if t > time and predicate(data):
            after = (t, *data)
            break
    return before, after


class Actor:
    def __init__(self, name, states=None, event_fn=None):
        self.name = name
        self.incoming = []
        self.outgoing = []
        self.states = states or {}
        self.time = None
        self.event_fn = event_fn
        self.state_log = []

    def event(self, participants, event, arguments=()):
        if self.event_fn is not None:
            self.event_fn(participants, event, arguments)
        if VERBOSE:
            print(
                f"EVENT\t{self.time} [{', '.join(participants)}] -> {event}; {arguments}"
            )

    def consume_matching(self, predicate):
        returned = [p for p in self.incoming if predicate(p)]
        self.incoming = [p for p in self.incoming if not predicate(p)]
        return returned

    def send(self, actor, message, priority=0):
        if VERBOSE:
            print(f"SEND\t{self.time}\t[{self.name}] -> [{actor}]: {message} {priority}")
        self.outgoing.append((actor, message, priority))

    def recv(self, source, message, priority=0):
        self.incoming.append((source, message, priority))
        if VERBOSE:
            print(f"RECV\t{self.time}\t[{source}] -> [{self.name}]: {message} {priority}")

    def get(self, state):
        return self.states.get(state, 0) > 0

    def enable(self, state):
        self.states[state] = self.states.get(state, 0) + 1
        self.state_log.append((self.time, state, True))
        if VERBOSE:
            print(f"ENABLE\t{self.time}\t{self.name} {state}")

    def disable(self, state):
        self.states[state] = max(self.states.get(state, 0) - 1, 0)
        self.state_log.append((self.time, state, False))
        if VERBOSE:
            print(f"DISABLE\t{self.time}\t{self.name} {state}")

    def state_at(self, time):
        # replay the log into a new set of states and return it
        states = {}
        for t, state, value in self.state_log:
            if t > time:
                break
            states[state] = value
        return states

    def toggle(self, state):
        self.states[state] = not self.states.get(state, False)
        self.state_log.append((self.time, state, self.states[state]))

    def query(self, state, time, value=None):
        before, after = query_timelog_around(
            self.state_log,
            time,
            lambda x: x[0] == state and (value is None or value == x[1]),
        )
        before = before[0] if before is not None else None
        after = after[0] if after is not None else None
        return before, after

    def query_range(self, state, start_time, end_time, value=None):
        q = query_timelog(
            self.state_log,
            start_time,
            end_time,
            lambda x: x[0] == state and (value is None or value == x[1]),
        )
        return [d[0] for d in q]

    def update(self):        
        self.incoming.sort(key=lambda x: x[2])
        for source, message, priority in self.incoming:
            self.process(source, message)
        self.incoming = []

    def has_incoming(self):
        return len(self.incoming) > 0

    def finalise(self):
        """Finalise is called after all messages have been processed.
        Messages in the finalise method will not be sent until
        the next update."""
        pass

    def initialise(self, time):
        """Initalise is called before any messages are processed."""
        self.time = time 


class ActorManager:
    def __init__(self):
        self.actors = {}
        self.time = None
        self.event_log = []
        self.queue = []

    def add_actor(self, actor):
        self.actors[actor.name] = actor
        actor.event_fn = self.event

    def event(self, participants, event, arguments):
        self.event_log.append((self.time, participants, event, arguments))

    def enqueue(self, source, target, message, priority):
        self.queue.append((source, target, message, priority))

    def send_to(self, source, target, message, priority):
        if target == "*":
            for actor in self.actors:
                self.actors[actor].recv(source, message, priority)
            return list(self.actors.values())
        else:
            if target not in self.actors:
                print(f"Actor {target} not found")
                return []
            else:
                self.actors[target].recv(source, message, priority)
                return [self.actors[target]]

    def update(self, time):
        self.time = time
        all_actors = list(self.actors.values())
        
        for actor in all_actors:
            actor.initialise(self.time)

        sorted_queue = sorted(self.queue, key=lambda x:x[3])
        self.queue = []
        # first, send messages to all targets in priority order
        for source, target, message, priority in sorted_queue:            
            actor_target = self.send_to(source, target, message, priority)
            for actor in actor_target:
                actor.update()
        first = True 
        # update actors until no more messages are pending
        while first or any(actor.has_incoming() for actor in all_actors):
            for actor in all_actors:
                actor.update()
            for actor in all_actors:
                actor.outgoing.sort(key=lambda x: x[2])
                for recipient, message, priority in actor.outgoing:
                    self.send_to(actor.name, recipient, message, priority)
                actor.outgoing = []
            first = False
        for actor in all_actors:
            actor.finalise()


class Bob(Actor):
    def process(self, source, message):
        if message == "wake":
            self.enable("awake")
        if message == "sleep":
            self.disable("awake")
        if message == "jump":
            if self.states.get("awake", False):
                self.enable("jump")
                self.send(self.name, "jumped", 0)
            else:
                print("Bob is asleep")
        if message == "jumped":
            before, after = self.query("jumped", self.time)
            if before is not None and self.time - before < 7:
                print("Bob is too tired to jump")
            else:
                print("Bob jumped")
                self.enable("jumped")
                self.event(["Bob"], "jumped", self.time)


if __name__ == "__main__":
    manager = ActorManager()
    b = Bob("Bob")
    manager.add_actor(b)
    for i in range(10):
        if random.random() < 0.2:
            manager.send_to("*", "Bob", "wake", 0)
        if random.random() < 0.2:
            manager.send_to("*", "Bob", "sleep", 0)
        manager.send_to("*", "Bob", "jump", 0)
        manager.update(i)
        print(b.query("jump", i))
        print(b.states)

    print(manager.event_log)
