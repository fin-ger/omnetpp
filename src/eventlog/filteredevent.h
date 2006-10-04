//=========================================================================
//  FILTEREDEVENT.H - part of
//                  OMNeT++/OMNEST
//           Discrete System Simulation in C++
//
//=========================================================================

/*--------------------------------------------------------------*
  Copyright (C) 1992-2006 Andras Varga

  This file is distributed WITHOUT ANY WARRANTY. See the file
  `license' for details on this and other legal matters.
*--------------------------------------------------------------*/

#ifndef __FILTEREDEVENT_H_
#define __FILTEREDEVENT_H_

#include <vector>
#include "eventlogdefs.h"
#include "ievent.h"
#include "event.h"

class FilteredEventLog;

/**
 * Events stored in the FilteredEventLog.
 *
 * Filtered events are in a lazy double-linked list based on event numbers.
 */
class FilteredEvent : public IEvent
{
    protected:
        FilteredEventLog *filteredEventLog;

        long eventNumber; // the corresponding event number
        long causeEventNumber; // the event number from which the message was sent that is being processed in this event
        FilteredMessageDependency *cause; // the message send which is processed in this event
        MessageDependencyList *causes; // the arrival message sends of messages which we send in this even and are in the filtered set
        MessageDependencyList *consequences; // the message sends and arrivals from this event to another in the filtered set

    public:
        FilteredEvent(FilteredEventLog *filteredEventLog, long eventNumber);
        ~FilteredEvent();

        IEvent *getEvent();

        // IEvent interface
        virtual EventEntry *getEventEntry() { return getEvent()->getEventEntry(); }
        virtual int getNumEventLogEntries() { return getEvent()->getNumEventLogEntries(); }
        virtual EventLogEntry *getEventLogEntry(int index) { return getEvent()->getEventLogEntry(index); }

        virtual int getNumEventLogMessages() { return getEvent()->getNumEventLogMessages(); }
        virtual EventLogMessage *getEventLogMessage(int index) { return getEvent()->getEventLogMessage(index); }

        virtual long getEventNumber() { return eventNumber; }
        virtual simtime_t getSimulationTime() { return getEvent()->getSimulationTime(); }
        virtual int getModuleId() { return getEvent()->getModuleId(); }
        virtual long getMessageId() { return getEvent()->getMessageId(); }
        virtual long getCauseEventNumber() { return getEvent()->getCauseEventNumber(); }

        virtual FilteredEvent *getPreviousEvent();
        virtual FilteredEvent *getNextEvent();

        virtual FilteredEvent *getCauseEvent();
        virtual FilteredMessageDependency *getCause();
        virtual MessageDependencyList *getCauses();
        virtual MessageDependencyList *getConsequences();

        virtual void print(FILE *file = stdout) { getEvent()->print(); }

    protected:
        MessageDependencyList *getCauses(IEvent *event, int consequenceMessageSendEntryNumber, int level);
        MessageDependencyList *getConsequences(IEvent *event, int causeMessageSendEntryNumber, int level);
};

#endif